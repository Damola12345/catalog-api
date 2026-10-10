// Package api implements a deliberately small REST API used to exercise the
// platform onboarding path (container, CI, Kubernetes, Terraform).
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// Item is the single resource exposed by the API.
type Item struct {
	ID    int     `json:"id"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
}

// Config holds runtime configuration, sourced from the environment
// (ConfigMap for non-sensitive values, Secret for the API key).
type Config struct {
	ServiceName string
	APIKey      string // required for write operations; empty disables writes
}

// Server is an in-memory item store with HTTP handlers.
type Server struct {
	cfg    Config
	log    *slog.Logger
	mu     sync.RWMutex
	items  map[int]Item
	nextID int
	ready  atomic.Bool
}

// New returns a Server seeded with sample data.
func New(cfg Config, log *slog.Logger) *Server {
	s := &Server{
		cfg:    cfg,
		log:    log,
		items:  map[int]Item{1: {ID: 1, Name: "widget", Price: 9.99}, 2: {ID: 2, Name: "gadget", Price: 24.50}},
		nextID: 3,
	}
	return s
}

// SetReady flips the readiness flag (false during startup and shutdown so the
// pod is removed from Service endpoints before it stops accepting traffic).
func (s *Server) SetReady(v bool) { s.ready.Store(v) }

// Routes wires up the HTTP mux.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /api/v1/items", s.listItems)
	mux.HandleFunc("GET /api/v1/items/{id}", s.getItem)
	mux.HandleFunc("POST /api/v1/items", s.requireKey(s.createItem))
	return s.logRequests(mux)
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready", "service": s.cfg.ServiceName})
}

func (s *Server) listItems(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Item, 0, len(s.items))
	for i := 1; i < s.nextID; i++ {
		if it, ok := s.items[i]; ok {
			out = append(out, it)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) getItem(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "id must be an integer")
		return
	}
	s.mu.RLock()
	it, ok := s.items[id]
	s.mu.RUnlock()
	if !ok {
		writeError(w, http.StatusNotFound, "item not found")
		return
	}
	writeJSON(w, http.StatusOK, it)
}

func (s *Server) createItem(w http.ResponseWriter, r *http.Request) {
	var in Item
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if err := validate(in); err != nil {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	s.mu.Lock()
	in.ID = s.nextID
	s.items[in.ID] = in
	s.nextID++
	s.mu.Unlock()
	writeJSON(w, http.StatusCreated, in)
}

func validate(in Item) error {
	if strings.TrimSpace(in.Name) == "" {
		return errors.New("name is required")
	}
	if in.Price < 0 {
		return errors.New("price must be >= 0")
	}
	return nil
}

// requireKey guards write endpoints with a static API key from a Secret.
// Constant-time comparison avoids timing side channels.
func (s *Server) requireKey(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-API-Key")
		if s.cfg.APIKey == "" || subtle.ConstantTimeCompare([]byte(got), []byte(s.cfg.APIKey)) != 1 {
			writeError(w, http.StatusUnauthorized, "missing or invalid API key")
			return
		}
		next(w, r)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		// Probe traffic is noisy; keep it at debug.
		level := slog.LevelInfo
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			level = slog.LevelDebug
		}
		s.log.Log(r.Context(), level, "request", "method", r.Method, "path", r.URL.Path, "status", rec.status)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
