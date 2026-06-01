// Package main is the tawon-pod-injector admission webhook entrypoint.
//
// Listens on HTTPS, accepts AdmissionReview requests from the
// Kubernetes apiserver at /mutate, decides whether the candidate Pod
// is a Tawon-managed pod, and (if so) returns a JSONPatch that adds
// hostNetwork=true and dnsPolicy=ClusterFirstWithHostNet.
//
// See internal/inject for the matching + patch logic and unit tests.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	"github.com/mimetrix/tawon-pod-injector/internal/inject"
)

const (
	defaultListenAddr   = ":8443"
	readHeaderTimeout   = 5 * time.Second
	writeTimeout        = 10 * time.Second
	idleTimeout         = 60 * time.Second
	shutdownGracePeriod = 10 * time.Second
	maxRequestBodyBytes = 1 << 20 // 1 MiB
)

// patchTypeJSONPatch is the only patch type Kubernetes admission
// webhooks may return today.
var patchTypeJSONPatch = admissionv1.PatchTypeJSONPatch

func main() {
	listen := flag.String("listen", defaultListenAddr, "HTTPS address to listen on (host:port)")
	certPath := flag.String("tls-cert", "/etc/webhook/certs/tls.crt", "TLS cert path (PEM)")
	keyPath := flag.String("tls-key", "/etc/webhook/certs/tls.key", "TLS key path (PEM)")
	logLevel := flag.String("log-level", "info", "log level: debug, info, warn, error")
	flag.Parse()

	logger := newLogger(*logLevel)
	slog.SetDefault(logger)

	logger.Info("tawon-pod-injector starting",
		"listen", *listen, "cert", *certPath)

	if err := run(*listen, *certPath, *keyPath, logger); err != nil {
		logger.Error("server exited with error", "err", err)
		os.Exit(1)
	}
	logger.Info("tawon-pod-injector stopped cleanly")
}

func run(listen, certPath, keyPath string, logger *slog.Logger) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/mutate", mutate)

	srv := &http.Server{
		Addr:              listen,
		Handler:           withRequestLimits(mux),
		ReadHeaderTimeout: readHeaderTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}

	serverErrs := make(chan error, 1)
	go func() {
		logger.Info("HTTPS listener starting", "addr", listen)
		if lerr := srv.ListenAndServeTLS(certPath, keyPath); lerr != nil && !errors.Is(lerr, http.ErrServerClosed) {
			serverErrs <- fmt.Errorf("listen: %w", lerr)
		}
	}()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	select {
	case lerr := <-serverErrs:
		return lerr
	case sig := <-sigs:
		logger.Info("shutdown signal received", "signal", sig.String())
	}

	ctx, cancel := context.WithTimeout(context.Background(), shutdownGracePeriod)
	defer cancel()
	return srv.Shutdown(ctx)
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

// mutate is the admission webhook handler. The apiserver POSTs an
// AdmissionReview here; we reply with a permissive AdmissionResponse
// whose `patch` is the JSONPatch to apply (or empty).
func mutate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		respondError(w, "", fmt.Errorf("read body: %w", err))
		return
	}
	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		respondError(w, "", fmt.Errorf("decode AdmissionReview: %w", err))
		return
	}
	if review.Request == nil {
		respondError(w, "", errors.New("missing admission request"))
		return
	}

	var pod corev1.Pod
	if err := json.Unmarshal(review.Request.Object.Raw, &pod); err != nil {
		respondError(w, string(review.Request.UID), fmt.Errorf("decode pod: %w", err))
		return
	}

	ops, err := inject.Patch(&pod)
	if err != nil {
		respondError(w, string(review.Request.UID), err)
		return
	}

	resp := &admissionv1.AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: true,
	}
	if patchBytes, mErr := inject.Marshal(ops); mErr != nil {
		respondError(w, string(review.Request.UID), mErr)
		return
	} else if patchBytes != nil {
		resp.Patch = patchBytes
		resp.PatchType = &patchTypeJSONPatch
		slog.Info("patched pod",
			"namespace", pod.Namespace,
			"name", pod.Name,
			"label", pod.Labels["app.kubernetes.io/name"],
			"ops", len(ops),
		)
	} else {
		slog.Debug("no-op",
			"namespace", pod.Namespace,
			"name", pod.Name,
			"label", pod.Labels["app.kubernetes.io/name"],
		)
	}

	respond(w, admissionv1.AdmissionReview{
		TypeMeta: review.TypeMeta,
		Response: resp,
	})
}

func respond(w http.ResponseWriter, review admissionv1.AdmissionReview) {
	out, err := json.Marshal(review)
	if err != nil {
		// At this point we can't even reply with a structured error;
		// return 500 and let the apiserver fail the admission with a
		// generic message.
		http.Error(w, "encode response: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(out)
}

// respondError sends a structured admission-deny response so the
// apiserver surfaces the cause to the user instead of a generic
// "webhook misbehaved" message.
func respondError(w http.ResponseWriter, uid string, err error) {
	slog.Error("admission error", "uid", uid, "err", err)
	respond(w, admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			UID:     types.UID(uid),
			Allowed: false,
			Result: &metav1.Status{
				Status:  "Failure",
				Message: err.Error(),
				Code:    http.StatusBadRequest,
			},
		},
	})
}

func withRequestLimits(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		defer func() {
			if rec := recover(); rec != nil {
				slog.Error("handler panic", "path", r.URL.Path, "panic", rec)
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: lvl}))
}
