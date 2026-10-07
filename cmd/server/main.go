// Ustame backend: mobil ilova, web-sayt va (keyinroq) Telegram bot uchun bitta API.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/api"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/config"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/jobs"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/telegram"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("baza: %v", err)
	}
	// Bir nechta ulanish doim ochiq turadi: yangi ulanish (TLS + parol) bazaga bir necha marta
	// borib-kelishni talab qiladi, birinchi so'rovni sekinlashtirmasligi uchun.
	poolCfg.MinConns = 2
	db, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		log.Fatalf("baza: %v", err)
	}
	defer db.Close()
	if err := db.Ping(ctx); err != nil {
		log.Fatalf("bazaga ulanib bo'lmadi: %v", err)
	}

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           api.New(cfg, db).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	// Mijoz 48 soat javob bermagan topshirilgan ishlar avtomatik qabul qilinadi
	go jobs.AutoApprove(ctx, db, 5*time.Minute)

	if cfg.TelegramBotToken != "" {
		bot := &telegram.Worker{
			TG:    &telegram.Client{Token: cfg.TelegramBotToken, HTTP: &http.Client{Timeout: 40 * time.Second}},
			Store: &telegram.PgStore{DB: db},
		}
		go bot.Run(ctx)
	} else {
		log.Print("TELEGRAM_BOT_TOKEN berilmagan — bildirishnomalar boti o'chiq")
	}

	go func() {
		log.Printf("Ustame backend :%s portda ishlayapti", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(shutdownCtx)
}
