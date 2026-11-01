// shop is a tiny two-service demo that emits all three signals with OpenTelemetry:
// traces and logs go to OpenSearch (via the Collector and Data Prepper), metrics go
// to Prometheus (via the Collector's OTLP push). One binary, three roles:
//
//	ROLE=checkout  GET /checkout  -> calls payments, counts orders
//	ROLE=payments  POST /pay      -> slow or failing on demand (see /chaos)
//	ROLE=loadgen   calls checkout a few times per second
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"
)

var logger *slog.Logger

func main() {
	role := env("ROLE", "checkout")
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := setupTelemetry(ctx, role)
	if err != nil {
		log.Fatalf("telemetry: %v", err)
	}
	defer shutdown(context.Background())
	logger = otelslog.NewLogger(role)

	switch role {
	case "checkout":
		err = serve(ctx, checkoutHandler())
	case "payments":
		err = serve(ctx, paymentsHandler())
	case "loadgen":
		loadgen(ctx)
	default:
		err = fmt.Errorf("unknown ROLE %q", role)
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func serve(ctx context.Context, h http.Handler) error {
	srv := &http.Server{Addr: ":8080", Handler: h}
	go func() { <-ctx.Done(); srv.Shutdown(context.Background()) }()
	log.Printf("listening on :8080")
	return srv.ListenAndServe()
}

// ---- checkout ----

func checkoutHandler() http.Handler {
	meter := otel.Meter("shop/checkout")
	orders, _ := meter.Int64Counter("shop.orders",
		metric.WithDescription("Orders placed, by result"), metric.WithUnit("{order}"))
	amount, _ := meter.Float64Histogram("shop.order.amount",
		metric.WithDescription("Order value"), metric.WithUnit("USD"),
		metric.WithExplicitBucketBoundaries(10, 25, 50, 100, 250, 500))

	client := http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport), Timeout: 5 * time.Second}
	paymentsURL := env("PAYMENTS_URL", "http://payments:8080") + "/pay"

	mux := http.NewServeMux()
	mux.HandleFunc("GET /checkout", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		user := fmt.Sprintf("user-%03d", rand.IntN(200))
		total := 5 + rand.Float64()*300
		trace.SpanFromContext(ctx).SetAttributes(attribute.String("app.user_id", user))

		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, paymentsURL, nil)
		resp, err := client.Do(req)
		if err == nil && resp.StatusCode >= 500 {
			err = fmt.Errorf("payments returned %s", resp.Status)
		}
		if resp != nil {
			resp.Body.Close()
		}
		if err != nil {
			orders.Add(ctx, 1, metric.WithAttributes(attribute.String("result", "failed")))
			logger.ErrorContext(ctx, "checkout failed", "user", user, "amount", total, "error", err.Error())
			http.Error(w, "payment failed", http.StatusBadGateway)
			return
		}
		orders.Add(ctx, 1, metric.WithAttributes(attribute.String("result", "ok")))
		amount.Record(ctx, total)
		logger.InfoContext(ctx, "order placed", "user", user, "amount", total)
		fmt.Fprintf(w, "ok %s %.2f\n", user, total)
	})
	return otelhttp.NewHandler(mux, "checkout")
}

// ---- payments ----

// chaos is the fault you inject with GET /chaos?latency_ms=800&error_rate=0.3.
type chaos struct {
	sync.Mutex
	latency   time.Duration
	errorRate float64
}

func paymentsHandler() http.Handler {
	var c chaos
	mux := http.NewServeMux()
	mux.HandleFunc("POST /pay", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		c.Lock()
		latency, errorRate := c.latency, c.errorRate
		c.Unlock()

		// Every payment calls a fake card provider; the injected latency lands here,
		// so the trace shows exactly which span got slow.
		_, span := otel.Tracer("shop/payments").Start(ctx, "card-provider.authorize")
		time.Sleep(20*time.Millisecond + time.Duration(rand.IntN(30))*time.Millisecond + latency)
		if rand.Float64() < errorRate {
			span.SetStatus(codes.Error, "card declined: provider timeout")
			span.End()
			logger.ErrorContext(ctx, "card provider timeout", "provider", "acme-pay", "latency_ms", latency.Milliseconds())
			http.Error(w, "provider timeout", http.StatusServiceUnavailable)
			return
		}
		span.End()
		if latency > 0 {
			logger.WarnContext(ctx, "slow card provider", "provider", "acme-pay", "latency_ms", latency.Milliseconds())
		}
		w.Write([]byte("paid\n"))
	})
	mux.HandleFunc("GET /chaos", func(w http.ResponseWriter, r *http.Request) {
		ms, _ := strconv.Atoi(r.URL.Query().Get("latency_ms"))
		rate, _ := strconv.ParseFloat(r.URL.Query().Get("error_rate"), 64)
		c.Lock()
		c.latency, c.errorRate = time.Duration(ms)*time.Millisecond, rate
		c.Unlock()
		logger.WarnContext(r.Context(), "chaos changed", "latency_ms", ms, "error_rate", rate)
		fmt.Fprintf(w, "chaos: latency=%dms error_rate=%.2f\n", ms, rate)
	})
	// /chaos itself is not traced, so it doesn't show up as a payments operation.
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chaos" {
			mux.ServeHTTP(w, r)
			return
		}
		otelhttp.NewHandler(mux, "payments").ServeHTTP(w, r)
	})
}

// ---- loadgen ----

func loadgen(ctx context.Context) {
	rps, _ := strconv.Atoi(env("RPS", "5"))
	url := env("CHECKOUT_URL", "http://checkout:8080") + "/checkout"
	client := http.Client{Timeout: 10 * time.Second}
	log.Printf("loadgen: %d req/s -> %s", rps, url)
	tick := time.NewTicker(time.Second / time.Duration(rps))
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			go func() {
				if resp, err := client.Get(url); err == nil {
					resp.Body.Close()
				}
			}()
		}
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
