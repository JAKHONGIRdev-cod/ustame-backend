// Kod generatsiya qilingan: ustago-ref/src/i18n (uz, ru) dagi survey.* matnlaridan. Qo'lda tahrirlamang —
// ilovadagi matn o'zgarsa qayta yasang (savollar va variant id'lari ustago-ref/src/lib/surveys.ts bilan bir xil).

package telegram

var prosSurvey = []surveyQuestion{
	{
		ID: "q1", Kind: "single",
		Text: map[string]string{"uz": "Qaysi sohada ishlaysiz?", "ru": "В какой сфере вы работаете?"},
		Options: []surveyOption{
			{ID: "plumbing", Text: map[string]string{"uz": "Santexnika", "ru": "Сантехника"}},
			{ID: "electric", Text: map[string]string{"uz": "Elektrika", "ru": "Электрика"}},
			{ID: "finishing", Text: map[string]string{"uz": "Ta'mirlash va pardozlash (suvoq, bo'yoq, kafel)", "ru": "Ремонт и отделка (штукатурка, покраска, плитка)"}},
			{ID: "construction", Text: map[string]string{"uz": "Qurilish (g'isht, beton, tom)", "ru": "Строительство (кирпич, бетон, кровля)"}},
			{ID: "furniture", Text: map[string]string{"uz": "Mebel va duradgorlik", "ru": "Мебель и столярные работы"}},
			{ID: "appliance", Text: map[string]string{"uz": "Maishiy texnika va konditsioner ta'miri", "ru": "Ремонт бытовой техники и кондиционеров"}},
			{ID: "other", Text: map[string]string{"uz": "Boshqa", "ru": "Другое"}},
		},
	},
	{
		ID: "q2", Kind: "single",
		Text: map[string]string{"uz": "Ish tugagach, mijoz kelishilgan pulni to'lamay ketgan holat bo'lganmi?", "ru": "Бывало, что после работы клиент не заплатил оговорённую сумму?"},
		Options: []surveyOption{
			{ID: "many", Text: map[string]string{"uz": "Ha, ko'p marta", "ru": "Да, много раз"}},
			{ID: "once", Text: map[string]string{"uz": "Ha, 1–2 marta", "ru": "Да, 1–2 раза"}},
			{ID: "never", Text: map[string]string{"uz": "Yo'q, bo'lmagan", "ru": "Нет, не было"}},
		},
	},
	{
		ID: "q3", Kind: "single",
		Text: map[string]string{"uz": "Ish tugagach, mijoz narxni tushirishga yoki \"kamroq beray\" deyishga uringanmi?", "ru": "Пытался ли клиент после работы сбить цену или «заплатить поменьше»?"},
		Options: []surveyOption{
			{ID: "always", Text: map[string]string{"uz": "Ha, deyarli har doim", "ru": "Да, почти всегда"}},
			{ID: "sometimes", Text: map[string]string{"uz": "Ba'zida", "ru": "Иногда"}},
			{ID: "rarely", Text: map[string]string{"uz": "Kamdan-kam", "ru": "Редко"}},
			{ID: "never", Text: map[string]string{"uz": "Hech qachon", "ru": "Никогда"}},
		},
	},
	{
		ID: "q4", Kind: "single",
		Text: map[string]string{"uz": "Mijoz bilan narx va ish hajmini qanday kelishasiz?", "ru": "Как вы договариваетесь с клиентом о цене и объёме работ?"},
		Options: []surveyOption{
			{ID: "oral", Text: map[string]string{"uz": "Faqat og'zaki", "ru": "Только устно"}},
			{ID: "chat", Text: map[string]string{"uz": "Telegram yoki SMS orqali yozma", "ru": "Письменно в Telegram или SMS"}},
			{ID: "paper", Text: map[string]string{"uz": "Qog'ozda shartnoma tuzamiz", "ru": "Заключаем договор на бумаге"}},
			{ID: "mixed", Text: map[string]string{"uz": "Har xil", "ru": "По-разному"}},
		},
	},
	{
		ID: "q5", Kind: "single",
		Text: map[string]string{"uz": "Materialni o'z pulingizga olib, pulini qaytarib ololmay qolgan holat bo'lganmi?", "ru": "Бывало, что вы купили материал за свои деньги и не смогли их вернуть?"},
		Options: []surveyOption{
			{ID: "lost", Text: map[string]string{"uz": "Ha, pulim qaytmagan", "ru": "Да, деньги не вернули"}},
			{ID: "late", Text: map[string]string{"uz": "Ha, lekin kechikib bo'lsa ham olganman", "ru": "Да, но с опозданием вернули"}},
			{ID: "never", Text: map[string]string{"uz": "Yo'q, materialni doim mijoz oladi yoki pulini oldin beradi", "ru": "Нет, материал всегда покупает клиент или платит заранее"}},
		},
	},
	{
		ID: "q6", Kind: "single",
		Text: map[string]string{"uz": "Yolg'on buyurtmaga duch kelganmisiz? (manzilga bordingiz, lekin mijoz yo'q yoki ish berilmadi)", "ru": "Сталкивались с ложным заказом? (приехали, а клиента нет или работу не дали)"},
		Options: []surveyOption{
			{ID: "many", Text: map[string]string{"uz": "Ha, ko'p marta", "ru": "Да, много раз"}},
			{ID: "once", Text: map[string]string{"uz": "Ha, 1–2 marta", "ru": "Да, 1–2 раза"}},
			{ID: "never", Text: map[string]string{"uz": "Yo'q", "ru": "Нет"}},
		},
	},
	{
		ID: "q7", Kind: "single",
		Text: map[string]string{"uz": "Mijoz \"shuni ham qilib keting\" deb, haqini oshirmasdan ishni ko'paytirganmi?", "ru": "Добавлял ли клиент работу («сделайте заодно и это») без доплаты?"},
		Options: []surveyOption{
			{ID: "always", Text: map[string]string{"uz": "Ha, deyarli har doim", "ru": "Да, почти всегда"}},
			{ID: "sometimes", Text: map[string]string{"uz": "Ba'zida", "ru": "Иногда"}},
			{ID: "never", Text: map[string]string{"uz": "Yo'q", "ru": "Нет"}},
		},
	},
	{
		ID: "q8", Kind: "single",
		Text: map[string]string{"uz": "Vositachi (brigadir, o'rtakash) pulingizni ushlab qolgan yoki to'lamagan holat bo'lganmi?", "ru": "Бывало, что посредник (бригадир) удержал или не выплатил ваши деньги?"},
		Options: []surveyOption{
			{ID: "yes", Text: map[string]string{"uz": "Ha", "ru": "Да"}},
			{ID: "no", Text: map[string]string{"uz": "Yo'q", "ru": "Нет"}},
			{ID: "none", Text: map[string]string{"uz": "Vositachi orqali ishlamayman", "ru": "Не работаю через посредников"}},
		},
	},
	{
		ID: "q9", Kind: "multi",
		Text: map[string]string{"uz": "Ishingizdagi eng katta muammolar qaysilar?", "ru": "Какие самые большие проблемы в вашей работе?"},
		Options: []surveyOption{
			{ID: "nonpayment", Text: map[string]string{"uz": "Pulni to'lamaslik yoki kechiktirish", "ru": "Неоплата или задержка оплаты"}},
			{ID: "price_cut", Text: map[string]string{"uz": "Narxni tushirish", "ru": "Снижение цены"}},
			{ID: "few_orders", Text: map[string]string{"uz": "Buyurtma kam, ish doimiy emas", "ru": "Мало заказов, работа нестабильная"}},
			{ID: "clients", Text: map[string]string{"uz": "Yangi mijoz topish qiyin", "ru": "Трудно найти новых клиентов"}},
			{ID: "trust", Text: map[string]string{"uz": "Mijoz va usta o'rtasida ishonch yo'q", "ru": "Нет доверия между клиентом и мастером"}},
			{ID: "materials", Text: map[string]string{"uz": "Material narxi tez o'zgaradi", "ru": "Цены на материалы быстро меняются"}},
			{ID: "other", Text: map[string]string{"uz": "Boshqa", "ru": "Другое"}},
		},
	},
	{
		ID: "q10", Kind: "text",
		Text: map[string]string{"uz": "Aldanib qolgan bir holatingizni qisqacha yozib bering", "ru": "Коротко опишите случай, когда вас обманули"},
	},
}

var surveyTexts = map[string]map[string]string{
	"intro":  {"uz": "Ustalar uchun so'rovnoma", "ru": "Опрос для мастеров"},
	"introText": {"uz": "Ish jarayonida duch keladigan muammolaringizni bilishimiz kerak — Ustame'ni shularni hal qiladigan qilib quramiz. Javoblaringiz faqat xizmatni yaxshilash uchun ishlatiladi.", "ru": "Нам важно знать, с какими проблемами вы сталкиваетесь в работе — мы строим Ustame, чтобы их решать. Ответы используются только для улучшения сервиса."},
	"pickUpTo": {"uz": "{n} tagacha belgilang", "ru": "Выберите до {n}"},
	"optional": {"uz": "Ixtiyoriy", "ru": "Необязательно"},
	"textPlaceholder": {"uz": "Qisqacha yozing…", "ru": "Коротко опишите…"},
	"thanksTitle": {"uz": "Rahmat!", "ru": "Спасибо!"},
	"thanksText": {"uz": "Javoblaringiz Ustame'ni ustalar uchun yanada foydali qilishga yordam beradi.", "ru": "Ваши ответы помогут сделать Ustame полезнее для мастеров."},
}
