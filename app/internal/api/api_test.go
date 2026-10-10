package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	s := New(Config{ServiceName: "test", APIKey: "secret"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	s.SetReady(true)
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(ts.Close)
	return ts
}

func do(t *testing.T, method, url, body string, headers map[string]string) int {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	return res.StatusCode
}

func TestEndpoints(t *testing.T) {
	ts := newTestServer(t)
	key := map[string]string{"X-API-Key": "secret"}

	tests := []struct {
		name    string
		method  string
		path    string
		body    string
		headers map[string]string
		want    int
	}{
		{"liveness", "GET", "/healthz", "", nil, 200},
		{"readiness", "GET", "/readyz", "", nil, 200},
		{"list", "GET", "/api/v1/items", "", nil, 200},
		{"get existing", "GET", "/api/v1/items/1", "", nil, 200},
		{"get missing", "GET", "/api/v1/items/999", "", nil, 404},
		{"get bad id", "GET", "/api/v1/items/abc", "", nil, 400},
		{"create no key", "POST", "/api/v1/items", `{"name":"x","price":1}`, nil, 401},
		{"create wrong key", "POST", "/api/v1/items", `{"name":"x","price":1}`, map[string]string{"X-API-Key": "nope"}, 401},
		{"create ok", "POST", "/api/v1/items", `{"name":"x","price":1}`, key, 201},
		{"create invalid json", "POST", "/api/v1/items", `{`, key, 400},
		{"create unknown field", "POST", "/api/v1/items", `{"name":"x","colour":"red"}`, key, 400},
		{"create empty name", "POST", "/api/v1/items", `{"name":" ","price":1}`, key, 422},
		{"create negative price", "POST", "/api/v1/items", `{"name":"x","price":-1}`, key, 422},
		{"method not allowed", "DELETE", "/api/v1/items/1", "", nil, 405},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := do(t, tc.method, ts.URL+tc.path, tc.body, tc.headers); got != tc.want {
				t.Fatalf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestNotReady(t *testing.T) {
	s := New(Config{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ts := httptest.NewServer(s.Routes())
	defer ts.Close()
	if got := do(t, "GET", ts.URL+"/readyz", "", nil); got != 503 {
		t.Fatalf("got %d, want 503 before SetReady(true)", got)
	}
}

func TestWritesDisabledWithoutKey(t *testing.T) {
	s := New(Config{APIKey: ""}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ts := httptest.NewServer(s.Routes())
	defer ts.Close()
	if got := do(t, "POST", ts.URL+"/api/v1/items", `{"name":"x"}`, map[string]string{"X-API-Key": ""}); got != 401 {
		t.Fatalf("got %d, want 401 when no API key is configured", got)
	}
}
