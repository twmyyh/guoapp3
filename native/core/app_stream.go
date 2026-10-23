package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

type nativeStreamAsset struct {
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
}

type nativeStreamSession struct {
	credentials *providerMediaCredentials
	mu          sync.Mutex
	assets      map[string]nativeStreamAsset
	referer     string
	key         []byte
	ctx         context.Context
	cancel      context.CancelFunc
	lastUsed    time.Time
	adBlock     bool
	order       []string
	warmMu      sync.Mutex
	warming     map[string]bool
	// warmSkip 记录「预取过一次但没戏」的分片（体积超限 / 上游拒绝 / 读取失败），
	// 避免同一个分片被反复拉取又丢弃，把带宽白白耗在没结果的请求上。
	warmSkip map[string]bool
	// warmed 记录本会话已预热进内存的字节数，用来卡住累计预算。
	warmed int64
}

// 播放中顺序预取（nativeWarmAhead）的边界。
//
// 预取只有在「上游单分片延迟高、同时带宽有余」时才是净收益。一旦上游限速
// （短剧站很常见），后台预取会和播放器正在拉的那一片抢同一条连接预算，把
// 当前分片拖慢，表现出来就是「播几秒就卡一下」。所以这里同时收紧三件事：
//
//   - 单片体积：超过 nativeWarmAheadSegmentLimit 的分片不预热。这类分片基本
//     是高码率/4K 片源，完整读进内存只会抬高堆占用和带宽占用；
//   - 会话预算：整个会话最多预热 nativeWarmAheadBudget 字节，用完即停。原先
//     没有这个上限，等于把整集分片逐条搬进内存且永不淘汰，堆随播放时长线性
//     增长，GC 越来越频繁，越播越卡；
//   - 预取窗口：只提前一片，覆盖一次网络往返即可，不再连拉两片。
const (
	nativeWarmAheadSegmentLimit = 3 << 20
	nativeWarmAheadBudget       = 24 << 20
)

type nativeStreamServer struct {
	mu         sync.Mutex
	downloader *Downloader
	address    string
	sessions   map[string]*nativeStreamSession
	server     *http.Server
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	return stream.downloader.doMediaRequestWithClient(request, &client)
}

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{downloader: d, address: "http://" + listener.Addr().String(), sessions: map[string]*nativeStreamSession{}}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServe), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() { _ = server.Serve(listener) }()
	return stream, nil
}

func (stream *nativeStreamServer) nativeOpen(media providerMedia, adBlock bool) (string, string) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, warming: map[string]bool{}, warmSkip: map[string]bool{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.credentials, adBlock: adBlock}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if time.Since(old.lastUsed) > 10*time.Minute {
			old.cancel()
			delete(stream.sessions, id)
		}
	}
	if len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		stream.sessions[oldest].cancel()
		delete(stream.sessions, oldest)
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{address: media.URL, contentType: "video/mp4"}
	if parsed, err := url.Parse(media.URL); err == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if media.Playlist != "" {
		entry.data = []byte(media.Playlist)
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	return stream.nativeAsset(token, session, entry), token
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		session.cancel()
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4":
		extension = ".mp4"
	}
	id := hex.EncodeToString(digest[:12]) + extension
	session.mu.Lock()
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
	session.mu.Unlock()
	return stream.address + "/" + token + "/" + id
}

func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, body, base string) (string, error) {
	var output []string
	var order []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference string, key bool, contentType string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			parsed, err := url.Parse(base)
			if err != nil {
				return ""
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := parsed.ResolveReference(relative).String()
			if !isProviderHTTPMediaURL(address) {
				return ""
			}
			asset := nativeStreamAsset{address: address, contentType: contentType}
			if key && len(session.key) == 16 {
				asset.data = append([]byte{}, session.key...)
				asset.contentType = "application/octet-stream"
			}
			return stream.nativeAsset(token, session, asset)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
			// 记录媒体分片的先后顺序，供播放中按序预取后续分片。
			if contentType == "" {
				if id := strings.TrimPrefix(line, stream.address+"/"+token+"/"); id != line && id != "" {
					order = append(order, id)
				}
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" {
					invalid = true
				}
				return "URI=\"" + updated + "\""
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	if len(order) > 0 {
		session.mu.Lock()
		session.order = order
		session.mu.Unlock()
	}
	return strings.Join(output, "\n"), nil
}

// nativeWarmAhead 在播放到某个分片时预取其后的若干分片。
//
// nativePrefetch 只在开播时预热一次，预热缓冲放完后每个分片都要现取，
// 上游延迟会在分片边界处表现为周期性的轻微卡顿；这里补充播放中的顺序预取。
func (stream *nativeStreamServer) nativeWarmAhead(session *nativeStreamSession, token, currentID string) {
	session.warmMu.Lock()
	// 预算用完说明这一集已经预取够了，剩下的交给播放器按需拉取。
	// 不加这道闸，整集分片会被逐条复制进内存且永不淘汰。
	if session.warmed >= nativeWarmAheadBudget {
		session.warmMu.Unlock()
		return
	}
	index := -1
	for i, id := range session.order {
		if id == currentID {
			index = i
			break
		}
	}
	if index < 0 {
		session.warmMu.Unlock()
		return
	}
	var targets []string
	for i := index + 1; i < len(session.order) && len(targets) < 1; i++ {
		id := session.order[i]
		if session.warming[id] || session.warmSkip[id] {
			continue
		}
		session.mu.Lock()
		asset, ok := session.assets[id]
		session.mu.Unlock()
		if ok && len(asset.data) > 0 {
			continue
		}
		session.warming[id] = true
		targets = append(targets, id)
	}
	session.warmMu.Unlock()
	for _, id := range targets {
		go stream.nativeWarmSegment(session, id)
	}
}

// nativeWarmSegment 后台取回单个分片并写入会话，使播放器请求时可直接命中缓存。
func (stream *nativeStreamServer) nativeWarmSegment(session *nativeStreamSession, id string) {
	// skip 置真的分支表示「这一片不值得再试」，由 defer 记进 warmSkip。
	skip := false
	defer func() {
		session.warmMu.Lock()
		delete(session.warming, id)
		if skip {
			session.warmSkip[id] = true
		}
		session.warmMu.Unlock()
	}()
	session.mu.Lock()
	asset, ok := session.assets[id]
	session.mu.Unlock()
	if !ok || len(asset.data) > 0 || strings.Contains(asset.contentType, "mpegurl") {
		return
	}
	ctx, cancel := context.WithCancel(providerMediaContext(session.ctx, session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.address, nil)
	if err != nil {
		skip = true
		return
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Referer", session.referer)
	response, err := stream.downloader.doMediaRequest(request)
	if err != nil {
		skip = true
		return
	}
	defer response.Body.Close()
	// 只接受完整响应：部分响应会在播放时触发范围请求，交给主路径处理更稳妥。
	if response.StatusCode != http.StatusOK {
		skip = true
		return
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, nativeWarmAheadSegmentLimit+1))
	if err != nil || len(body) == 0 {
		skip = true
		return
	}
	if int64(len(body)) > nativeWarmAheadSegmentLimit {
		// 大分片（4K / 高码率）不预热：完整读进来只会抬高堆占用，而且会和
		// 播放器正在拉的当前分片抢带宽。记下来不再重试。
		skip = true
		return
	}
	asset.data = body
	asset.total = int64(len(body))
	asset.etag, asset.modified = response.Header.Get("ETag"), response.Header.Get("Last-Modified")
	if response.Request != nil && response.Request.URL != nil {
		asset.address = response.Request.URL.String()
	}
	session.mu.Lock()
	session.assets[id] = asset
	session.mu.Unlock()
	session.warmMu.Lock()
	session.warmed += int64(len(body))
	session.warmMu.Unlock()
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	session.mu.Lock()
	asset, found := session.assets[parts[1]]
	session.mu.Unlock()
	if !found {
		http.NotFound(writer, request)
		return
	}
	if !strings.Contains(asset.contentType, "mpegurl") {
		stream.nativeWarmAhead(session, parts[0], parts[1])
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if len(asset.data) > 0 && asset.total > int64(len(asset.data)) {
		if stream.nativeServePrefix(ctx, writer, request, session, asset) {
			return
		}
		asset.data = nil
	}
	if len(asset.data) > 0 {
		if strings.Contains(asset.contentType, "mpegurl") {
			body, err := stream.nativeRewrite(parts[0], session, nativeAdCleaned(session, string(asset.data), asset.address), asset.address)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if request.Method == http.MethodGet {
				_, _ = io.WriteString(writer, body)
			}
		} else {
			writer.Header().Set("Content-Type", asset.contentType)
			if asset.etag != "" {
				writer.Header().Set("ETag", asset.etag)
			}
			http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(asset.data))
		}
		return
	}
	upstream, err := http.NewRequestWithContext(ctx, request.Method, asset.address, nil)
	if err != nil {
		http.Error(writer, "媒体地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Referer", session.referer)
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	playlist := strings.Contains(asset.contentType, "mpegurl") || strings.Contains(contentType, "mpegurl") || strings.HasSuffix(strings.ToLower(finalURL.Path), ".m3u8")
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, err := io.ReadAll(io.LimitReader(response.Body, 4<<20+1))
		if err != nil || len(body) > 4<<20 {
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
		if !strings.HasPrefix(text, "#EXTM3U") {
			http.Error(writer, "播放列表无效", http.StatusBadGateway)
			return
		}
		text = nativeAdCleaned(session, text, finalURL.String())
		rewritten, err := stream.nativeRewrite(parts[0], session, text, finalURL.String())
		if err != nil {
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, rewritten)
		return
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, response.Body)
	}
}
