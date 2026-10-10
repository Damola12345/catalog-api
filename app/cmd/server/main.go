// Command server runs the catalog-api HTTP service.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Damola12345/catalog-api/internal/api"
)

// version is injected at build time via -ldflags "-X main.version=<git sha>".
var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: parseLevel(getenv("LOG_LEVEL", "info"))})).
		With("service", getenv("SERVICE_NAME", "catalog-api"), "version", version)

	srv := api.New(api.Config{
		ServiceName: getenv("SERVICE_NAME", "catalog-api"),
		APIKey:      os.Getenv("API_KEY"),
	}, log)

	httpSrv := &http.Server{
		Addr:              ":" + getenv("PORT", "8080"),
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Info("starting", "addr", httpSrv.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	srv.SetReady(true)

	<-ctx.Done()
	// Graceful shutdown: fail readiness first so kube-proxy / the ingress
	// controller drain this pod, then stop accepting connections.
	srv.SetReady(false)
	log.Info("shutdown signal received, draining")
	time.Sleep(parseDuration(getenv("SHUTDOWN_DRAIN", "5s")))

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	log.Info("stopped")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func parseLevel(s string) slog.Level {
	var l slog.Level
	if err := l.UnmarshalText([]byte(s)); err != nil {
		return slog.LevelInfo
	}
	return l
}

func parseDuration(s string) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil {
		return 5 * time.Second
	}
	return d
}
