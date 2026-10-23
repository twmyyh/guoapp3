package core

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// warmTestSession 构造一个只填了必要字段的分片会话，供预热用例直接驱动。
func warmTestSession(server *httptest.Server, names ...string) *nativeStreamSession {
	session := &nativeStreamSession{
		assets:   map[string]nativeStreamAsset{},
		warming:  map[string]bool{},
		warmSkip: map[string]bool{},
		ctx:      context.Background(),
	}
	session.cancel = func() {}
	for _, name := range names {
		session.assets[name] = nativeStreamAsset{
			address:     server.URL + "/" + name,
			contentType: "video/mp4",
		}
		session.order = append(session.order, name)
	}
	return session
}

func warmTestStream(t *testing.T) *nativeStreamServer {
	t.Helper()
	// 媒体请求走 ProxyFromEnvironment，测试必须绕开本机代理，否则打到
	// 127.0.0.1 的请求会被转发出去而失败。
	t.Setenv("NO_PROXY", "*")
	t.Setenv("no_proxy", "*")
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stream.server.Close() })
	return stream
}

// TestWarmAheadSkipsOversizeSegment 大分片（超过单片上界）不该被搬进内存：
// 既白占堆，又会和播放器正在拉的当前分片抢带宽。跳过一次后要记住，
// 不能再反复重试同一个分片。
func TestWarmAheadSkipsOversizeSegment(t *testing.T) {
	var hits int32
	payload := bytes.Repeat([]byte{0x47}, nativeWarmAheadSegmentLimit+1024)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Header().Set("Content-Type", "video/mp4")
		_, _ = w.Write(payload)
	}))
	defer server.Close()

	stream := warmTestStream(t)
	session := warmTestSession(server, "big.ts")
	stream.nativeWarmSegment(session, "big.ts")

	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("超大分片应只被请求 1 次，实际 %d", got)
	}
	if len(session.assets["big.ts"].data) != 0 {
		t.Fatal("超大分片不应缓存进内存")
	}
	if !session.warmSkip["big.ts"] {
		t.Fatal("超大分片应被标记为不再预取")
	}
	// 只有这一片时，再次触发预热不应重新请求它。
	stream.nativeWarmAhead(session, "token", "big.ts")
	time.Sleep(50 * time.Millisecond)
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("已被跳过的分片不应被重试，实际请求 %d 次", got)
	}
}

// TestWarmAheadStopsAtBudget 会话累计预热达到预算后必须彻底停止，
// 否则整集分片会被逐条复制进内存且永不淘汰（越播越卡的主因）。
func TestWarmAheadStopsAtBudget(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Header().Set("Content-Type", "video/mp4")
		_, _ = w.Write(bytes.Repeat([]byte{0x47}, 64*1024))
	}))
	defer server.Close()

	stream := warmTestStream(t)
	session := warmTestSession(server, "a.ts", "b.ts", "c.ts")
	session.warmed = nativeWarmAheadBudget
	stream.nativeWarmAhead(session, "token", "a.ts")
	time.Sleep(100 * time.Millisecond)

	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("预算用尽后不应再发起预取，实际请求 %d 次", got)
	}
}

// TestWarmAheadPrefetchesSingleSegment 播放中只提前一片，
// 不再一次连拉两片（那会和当前分片抢同一条连接预算）。
func TestWarmAheadPrefetchesSingleSegment(t *testing.T) {
	var hits int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Header().Set("Content-Type", "video/mp4")
		_, _ = w.Write(bytes.Repeat([]byte{0x47}, 64*1024))
	}))
	defer server.Close()

	stream := warmTestStream(t)
	session := warmTestSession(server, "a.ts", "b.ts", "c.ts")
	stream.nativeWarmAhead(session, "token", "a.ts")

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(session.assets["b.ts"].data) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(session.assets["b.ts"].data) == 0 {
		t.Fatal("应预取当前分片的下一片")
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("单次只应预取 1 片，实际请求 %d 次", got)
	}
	// 预取成功后会计入预算，预算只累计真实缓存下来的字节。
	if session.warmed <= 0 || session.warmed > nativeWarmAheadBudget {
		t.Fatalf("预算累计异常：%d", session.warmed)
	}
}
