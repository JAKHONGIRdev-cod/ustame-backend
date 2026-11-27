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
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/push"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/telegram"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/wakeup"
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
	// Neon bepul tarifida baza 5 daqiqa tinch tursa uxlaydi (oylik hisoblash soatlari tejaladi).
	// Doimiy ochiq ulanish saqlamaymiz va bo'sh ulanishni undan oldin yopamiz.
	poolCfg.MinConns = 0
	poolCfg.MaxConnIdleTime = 4 * time.Minute
	db, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		log.Fatalf("baza: %v", err)
	}
	defer db.Close()
	if err := db.Ping(ctx); err != nil {
		log.Fatalf("bazaga ulanib bo'lmadi: %v", err)
	}

	// Bazani doimiy so'rab turish o'rniga: API yozuvdan keyin signal beradi, ishchilar shuni kutadi
	outbox, activity := &wakeup.Hub{}, &wakeup.Hub{}
	app := api.New(cfg, db)
	app.Outbox, app.Activity = outbox, activity

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           app.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	// Mijoz 48 soat javob bermagan topshirilgan ishlar avtomatik qabul qilinadi: baza uyg'oq paytda
	// (API faolligi, 10 daqiqada ko'pi bilan bir marta) yoki zaxira sifatida 6 soatda bir marta
	go jobs.AutoApprove(ctx, db, activity.Subscribe(), 10*time.Minute, 6*time.Hour, outbox.Notify)
	// Telefonlarga push-bildirishnomalar (Expo) — Telegram botidan mustaqil
	expo := &push.Client{AccessToken: cfg.ExpoAccessToken, HTTP: &http.Client{Timeout: 20 * time.Second}}
	pushStore := &push.PgStore{DB: db}
	// Push yuborilgach ~15 daqiqada Expo receipt'lari: telefonga yetdimi, o'lik tokenlar o'chiriladi (2026-11-23)
	pushSent := make(chan struct{}, 1)
	pusher := &push.Worker{
		Expo:  expo,
		Store: pushStore,
		Wake:  outbox.Subscribe(),
		Sent:  pushSent,
	}
	go pusher.Run(ctx)
	receipts := &push.ReceiptWorker{Expo: expo, Store: pushStore, Kick: pushSent}
	go receipts.Run(ctx)

	if cfg.TelegramBotToken != "" {
		tgStore := &telegram.PgStore{DB: db}
		bot := &telegram.Worker{
			TG:    &telegram.Client{Token: cfg.TelegramBotToken, HTTP: &http.Client{Timeout: 40 * time.Second}},
			Store: tgStore,
			Wake:  outbox.Subscribe(),
			// Bot kirish kodini ham bera oladi (havola ishlamasa): /api/auth/verify shu kalit bilan tekshiradi
			OTPSecret: cfg.OTPSecret,
			// Raqam so'ralganda: «Raqamni yuborish» tugmasi qayerda va «OK» — rasmli ko'rsatma (saytdagi fayl)
			HelpPhotoURL: "https://ustame.com/tg-help/raqam-yuborish.png",
		}
		// «Usta chaqirish»: mijoz botning o'zida e'lon beradi (internal/telegram/order.go).
		// TELEGRAM_ORDERS: off (standart) | test (faqat ORDER_TEST_PHONES) | on (hamma uchun)
		if mode := telegram.ParseOrderMode(cfg.TelegramOrders); mode != telegram.OrdersOff {
			bot.Orders = tgStore
			bot.OrderMode = mode
			bot.OrderTestPhones = map[string]bool{}
			for _, p := range cfg.OrderTestPhones {
				bot.OrderTestPhones[p] = true
			}
			bot.OutboxNotify = outbox.Notify
			if cfg.STTAPIKey != "" {
				bot.STT = &telegram.OpenAISTT{APIKey: cfg.STTAPIKey, URL: cfg.STTURL, Model: cfg.STTModel,
					HTTP: &http.Client{Timeout: 45 * time.Second}}
				bot.STTName = telegram.STTProviderName(cfg.STTURL)
			} else {
				log.Print("STT_API_KEY berilmagan — bot ovozli xabarni qabul qilmaydi (faqat matn)")
			}
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
