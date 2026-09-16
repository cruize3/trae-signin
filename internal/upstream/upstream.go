// Package upstream 封装 TRAE SOLO 签到、积分查询、Token 刷新等上游 API。
package upstream

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"trae-signin/internal/auth"
)

const (
	UgHost         = "https://api.trae.cn"
	OAuthHost      = "https://api.trae.com.cn"
	ClientID       = "en1oxy7wnw8j9n"
	IdeVersion     = "0.1.43"
	IdeVersionCode = "20260716"

	EpExchange      = "/cloudide/api/v3/trae/oauth/ExchangeToken"
	EpCheckinStatus = "/trae/api/v2/ug/checkin_credits/status"
	EpCheckinClaim  = "/trae/api/v2/ug/checkin_credits/claim"
	EpEntUsage      = "/trae/api/v2/pay/ide_user_ent_usage"
)

var clientUA = "Trae/" + IdeVersion

type Client struct {
	HTTP *http.Client
}

func New() *Client {
	tr := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	}
	return &Client{
		HTTP: &http.Client{Timeout: 60 * time.Second, Transport: tr},
	}
}

func (c *Client) doJSON(req *http.Request) (json.RawMessage, error) {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, truncate(string(raw), 200))
	}
	return raw, nil
}

// RefreshToken 通过 ExchangeToken 强制刷新 access token。
func (c *Client) RefreshToken(a *auth.Auth) error {
	a.Lock()
	defer a.Unlock()

	if strings.TrimSpace(a.RefreshToken) == "" {
		return fmt.Errorf("no refreshToken")
	}
	host := a.ApiHost
	if host == "" {
		host = OAuthHost
	}
	body := map[string]any{
		"ClientID":     ClientID,
		"RefreshToken": a.RefreshToken,
		"ClientSecret": "-",
		"UserID":       "",
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, host+EpExchange, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", clientUA)

	data, err := c.doJSON(req)
	if err != nil {
		return err
	}
	var resp struct {
		Result struct {
			Token               string `json:"Token"`
			TokenExpireAt       int64  `json:"TokenExpireAt"`
			TokenExpireDuration int64  `json:"TokenExpireDuration"`
			RefreshToken        string `json:"RefreshToken"`
		} `json:"Result"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return fmt.Errorf("exchange parse: %w", err)
	}
	if resp.Result.Token == "" {
		return fmt.Errorf("refresh_failed: no token — re-login required")
	}
	a.AccessToken = resp.Result.Token
	if resp.Result.RefreshToken != "" {
		a.RefreshToken = resp.Result.RefreshToken
	}
	if resp.Result.TokenExpireAt > 0 {
		exp := resp.Result.TokenExpireAt
		if exp > 1e12 {
			exp /= 1000
		}
		a.ExpiresAt = exp
	} else if resp.Result.TokenExpireDuration > 0 {
		a.ExpiresAt = time.Now().Add(time.Duration(resp.Result.TokenExpireDuration) * time.Second).Unix()
	}
	return nil
}

// ugEnvelope 是 /trae/api/v2/ug/* 的统一业务响应壳：HTTP 恒为 200，
// 成败必须看顶层 code（0 成功，非 0 见 message）。
type ugEnvelope struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

// CheckinStatus 查询签到状态。
func (c *Client) CheckinStatus(a *auth.Auth) (checkedIn bool, credits int64, enable bool, err error) {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpCheckinStatus, bytes.NewReader([]byte("{}")))
	if err != nil {
		return false, 0, false, err
	}
	ugHeaders(req, a)
	data, err := c.doJSON(req)
	if err != nil {
		return false, 0, false, err
	}
	var resp struct {
		ugEnvelope
		CheckedIn    bool  `json:"checked_in"`
		DidCheckedIn bool  `json:"did_checked_in"`
		Credits      int64 `json:"credits"`
		Enable       bool  `json:"enable"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return false, 0, false, fmt.Errorf("checkin status parse: %w", err)
	}
	if resp.Code != 0 {
		return false, 0, false, fmt.Errorf("checkin status failed: code=%d %s", resp.Code, truncate(resp.Message, 120))
	}
	return resp.CheckedIn, resp.Credits, resp.Enable, nil
}

// CheckinClaim 执行签到。
// 官方客户端（Trae CN.app）POST body 固定为 {"req_source":1}（Work/SOLO CN 端）；
// 发空对象 {} 时服务端不执行任何操作却仍返回 HTTP 200/code=0，会造成“假成功”。
// 因此 code=0 后还必须回查 status，确认 checked_in 已翻转才算真正成功。
func (c *Client) CheckinClaim(a *auth.Auth) error {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpCheckinClaim,
		bytes.NewReader([]byte(`{"req_source":1}`)))
	if err != nil {
		return err
	}
	ugHeaders(req, a)

	var env ugEnvelope
	// 9004「订单参数错误」与 9074「当前参与用户太多」在快速重复请求/服务端瞬时
	// 繁忙时也会出现，做一次短暂退避重试。注意：device_id 未注册时 9074 是确定性
	// 拒绝，重试无效，错误消息会原样返回供排查。
	for attempt := 0; ; attempt++ {
		data, err := c.doJSON(req)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(data, &env); err != nil {
			return fmt.Errorf("checkin claim parse: %w", err)
		}
		if env.Code == 0 || attempt >= 1 {
			break
		}
		if env.Code != 9004 && env.Code != 9074 {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if env.Code != 0 {
		// 9095: 同一设备今日已被其他账号签到，服务端按设备限制每天一次
		if env.Code == 9095 {
			return fmt.Errorf("此设备今日已签到（多账号共用同一 device_id，每日仅首个账号可签到）")
		}
		return fmt.Errorf("code=%d %s", env.Code, truncate(env.Message, 120))
	}

	// 回查服务端真实状态，防止“code=0 但什么都没发生”的假成功。
	checkedIn, _, _, serr := c.CheckinStatus(a)
	if serr != nil {
		return fmt.Errorf("claim acknowledged but status verify error: %w", serr)
	}
	if !checkedIn {
		return fmt.Errorf("checkin claim acknowledged (code=0) but server status is still not checked in")
	}
	return nil
}

// UserEntUsage 查询积分余额。
func (c *Client) UserEntUsage(a *auth.Auth) (remain int64, err error) {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpEntUsage, bytes.NewReader([]byte("{}")))
	if err != nil {
		return 0, err
	}
	ugHeaders(req, a)
	data, err := c.doJSON(req)
	if err != nil {
		return 0, err
	}
	var resp struct {
		UserEntitlementPackList []struct {
			EntitlementBaseInfo struct {
				Quota struct {
					CreditsLimit int64 `json:"credits_limit"`
				} `json:"quota"`
			} `json:"entitlement_base_info"`
		} `json:"user_entitlement_pack_list"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return 0, fmt.Errorf("ent usage parse: %w", err)
	}
	for _, p := range resp.UserEntitlementPackList {
		remain += p.EntitlementBaseInfo.Quota.CreditsLimit
	}
	return remain, nil
}

func ugHeaders(req *http.Request, a *auth.Auth) {
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", clientUA)
	req.Header.Set("Authorization", "Cloud-IDE-JWT "+a.JWT())
	req.Header.Set("X-User-Region", "CN")
	// 以下设备头与官方客户端 _applyUgDeviceHeaders 对齐；
	// 缺失时 checkin_credits/claim 可能返回 9004「订单参数错误」。
	req.Header.Set("x-device-brand", "PC")
	req.Header.Set("x-device-type", "PC")
	req.Header.Set("x-os-version", "1.0")
	req.Header.Set("x-app-version", IdeVersion)
	if a.DeviceID != "" {
		req.Header.Set("x-device-id", a.DeviceID)
	}
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
