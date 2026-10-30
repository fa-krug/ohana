--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;

--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY auth.users (id, email) FROM stdin;
00000000-0000-0000-0000-000000000001	someone@supabase.example
\.


--
-- Data for Name: families; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.families (id, name, created_at, updated_at, feed_id, legacy_id) FROM stdin;
fpKrugFamily00000001	Krug	2024-05-01 10:00:00.123456+00	2026-09-30 08:15:00+00	feedKrug000000000001	legacyKrug0000000001
fpOmaFamily000000002	Oma & Opa	2025-01-02 09:30:00+01	2025-01-02 09:30:00+01	feedOma0000000000002	\N
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, email, name, password_hash, is_admin, must_change_password, created_at, updated_at) FROM stdin;
fpUserAnna000000001	anna@example.com	Anna Krug	pbkdf2-sha256$1000$c2FsdHNhbHRzYWx0c2FsdA==$y771VGzww0JAKhG7KpIUpf2gl1an+1lmGXYdIXUsgjc=	f	f	2024-05-01 10:00:00+00	2024-05-01 10:00:00+00
fpUserAdmin00000002	admin		pbkdf2-sha256$1000$YWRtaW5zYWx0YWRtaW5zYQ==$XeKFsodc29bW9InFUccaipi139/0qRZMz5OdJH4jung=	t	t	2024-04-01 10:00:00+00	2024-04-01 10:00:00+00
fpUserBen0000000003	ben@example.com	Ben	\N	f	f	2024-06-01 10:00:00+00	2024-06-01 10:00:00+00
\.


--
-- Data for Name: auth_tokens; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_tokens (id, hash, user_id, kind, name, can_reset, created_at, last_used_at, expires_at) FROM stdin;
fpTokenApi00000001	330f6ab987b5632d7ec3dfdd0bf567039e13a87e748b6c321a25636d85e0a23f	fpUserAnna000000001	api	Home Assistant	f	2025-02-01 10:00:00+00	2026-10-01 07:00:00+00	\N
fpTokenSess0000002	c101e911469c969171040b50d70543313cf968fdef5bacc780776f8fb399ab36	fpUserAnna000000001	session		f	2026-10-01 07:00:00+00	\N	2026-12-01 07:00:00+00
fpTokenSetup000003	8997ec9a3da1e44792b936f9baffd674262900d5af8bfdeab23512d11766de09	fpUserBen0000000003	setup		f	2026-10-01 07:00:00+00	\N	2026-10-02 07:00:00+00
\.


--
-- Data for Name: passkeys; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.passkeys (id, user_id, public_key, counter, transports, rp_id, name, created_at, last_used_at) FROM stdin;
credAnna	fpUserAnna000000001	pQECAyYgASFYIA	3	{internal,hybrid}	family-planner.fa-krug.de	iPhone	2025-02-01 10:00:00+00	\N
\.


--
-- Data for Name: family_members; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.family_members (family_id, user_id, role, created_at) FROM stdin;
fpKrugFamily00000001	fpUserAnna000000001	editor	2024-05-01 10:00:00+00
fpKrugFamily00000001	fpUserBen0000000003	viewer	2024-06-01 10:00:00+00
fpOmaFamily000000002	fpUserAdmin00000002	editor	2025-01-02 09:30:00+00
fpOmaFamily000000002	fpUserBen0000000003	viewer	2025-01-03 09:30:00+00
\.


--
-- Data for Name: entry_types; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.entry_types (family_id, id, name, color, role, "position", year) FROM stdin;
fpKrugFamily00000001	vacation	Urlaub	#22c55e	covers	0	2026
fpKrugFamily00000001	holiday	Feiertag	#f59e0b	day_off	1	2026
fpKrugFamily00000001	kita	Kita zu	#ef4444	needs_cover	2	2026
fpKrugFamily00000001	vacation	Urlaub	#22c55e	covers	0	2025
fpOmaFamily000000002	sick	Krank	#64748b	none	0	2026
\.


--
-- Data for Name: day_entries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.day_entries (family_id, day, type_id) FROM stdin;
fpKrugFamily00000001	2026-07-01	vacation
fpKrugFamily00000001	2026-07-02	vacation
fpKrugFamily00000001	2026-07-02	kita
fpKrugFamily00000001	2025-12-24	vacation
fpOmaFamily000000002	2026-03-03	sick
\.


--
-- Data for Name: day_notes; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.day_notes (family_id, day, icon, comment) FROM stdin;
fpKrugFamily00000001	2026-12-24	🎄	Heiligabend\tbei Oma\nab 15 Uhr
fpKrugFamily00000001	2026-07-01		Back\\slash
\.


--
-- Data for Name: family_settings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.family_settings (family_id, currency, csv_mappings, benchmark) FROM stdin;
fpKrugFamily00000001	EUR	[{"date": 0, "debit": null, "payee": 2, "amount": 4, "credit": null, "decimal": ",", "encoding": "utf-8", "skipRows": 4, "accountId": "giro", "delimiter": ";", "hasHeader": true, "signature": "Buchungstag;Wertstellung;Empf\\u00e4nger;Verwendungszweck;Betrag", "dateFormat": "dd.mm.yyyy", "description": [3]}]	{"label": "Destatis 2023", "income": {"lowCents": 400000, "highCents": 500000}, "expense": {"lowCents": 350000, "highCents": 350000}, "categories": [{"lowCents": 50000, "highCents": 60000, "categoryId": "food"}]}
fpOmaFamily000000002	CHF	[]	\N
\.


--
-- Data for Name: finance_accounts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.finance_accounts (family_id, id, name, color, icon, opening_cents, "position") FROM stdin;
fpKrugFamily00000001	giro	Girokonto	#3b82f6	🏦	100000	0
fpKrugFamily00000001	savings	Sparkonto	#a855f7	🐷	500000	1
\.


--
-- Data for Name: finance_categories; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.finance_categories (family_id, id, name, color, icon, kind, "position", parent_id) FROM stdin;
fpKrugFamily00000001	bakery	Bäckerei	#f97316	🥐	expense	0	groceries
fpKrugFamily00000001	groceries	Lebensmittel	#22c55e	🛒	expense	0	food
fpKrugFamily00000001	food	Essen	#16a34a	🍽️	expense	0	\N
fpKrugFamily00000001	salary	Gehalt	#0ea5e9	💼	income	1	\N
fpKrugFamily00000001	household	Haushalt	#eab308	🏠	expense	2	\N
\.


--
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.transactions (family_id, id, day, amount_cents, payee, description, category_id, note, import_hash, created_at, account_id, transfer_id, split_of) FROM stdin;
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000005	2026-10-05	-3000	Amazon	Bestellnr. 302-1 Brötchenbackmischung	bakery	für\tSonntag\nund Montag	\N	2026-10-06 09:00:00.250123+00	giro	\N	aaaaaaaa-0000-4000-8000-000000000004
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000006	2026-10-05	-2000	Amazon	Bestellnr. 302-1 Nudeln	groceries		\N	2026-10-06 09:00:00.250123+00	giro	\N	aaaaaaaa-0000-4000-8000-000000000004
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000001	2026-09-30	300000	Arbeitgeber GmbH	Gehalt September	salary		dkb:2026-09-30:300000:arbeitgeber	2026-10-01 08:00:00.123456+00	giro	\N	\N
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000002	2026-10-02	-50000		Sparen	\N		\N	2026-10-02 07:00:00+00	giro	bbbbbbbb-0000-4000-8000-000000000001	\N
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000003	2026-10-02	50000		Sparen	\N		\N	2026-10-02 07:00:00+00	savings	bbbbbbbb-0000-4000-8000-000000000001	\N
fpKrugFamily00000001	aaaaaaaa-0000-4000-8000-000000000004	2026-10-05	-8000	Amazon	Bestellnr. 302-1	household		\N	2026-10-06 09:00:00.250123+00	giro	\N	\N
\.


--
-- Data for Name: ai_settings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ai_settings (family_id, base_url, model, api_key_enc, search_provider, search_key_enc, allow_writes, updated_at, context_window) FROM stdin;
fpKrugFamily00000001	https://api.openai.com/v1	gpt-4o-mini	v1:c7IoXYKFtsnq5u2OhXIZSLHPH7NzhMFW3TT6uNW/GSk/SwTbK4bGFXozC68HugIkrQ==	tavily	v1:srWidrq0bmz5FcCxYPNFXPwoQglzAAcCy48/Zpbg77ZLvG/+Iv3OsU65+Su5og==	f	2026-10-01 07:00:00+00	64000
fpOmaFamily000000002	https://openrouter.ai/api/v1	mistral-small	v1:bB0PO5w7lCVUhCLo01B609CHliky6sm6zmIQrxBZv70a0Z+IoHLl5mK2lQ==	none		t	2026-09-01 07:00:00+00	0
\.


--
-- Data for Name: ai_chats; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ai_chats (id, family_id, user_id, title, status, run_token, run_until, stop, retries, context, activity, notes, rev, created_at, updated_at, usage, queue) FROM stdin;
fpChatIdle0000000001	fpKrugFamily00000001	fpUserAnna000000001	Urlaub planen	idle	\N	\N	f	0	{"day": "2026-10-01", "lang": "de", "page": "calendar", "year": 2026}	\N	["Undid: vacation on 2026-08-03"]	3	2026-10-01 07:00:00.123456+00	2026-10-01 07:01:30.456789+00	{"max": 128000, "used": 2100}	[]
fpChatRunning0000002	fpOmaFamily000000002	fpUserAdmin00000002	Wetter	running	tok-held-by-edge	2026-10-02 08:00:30+00	f	2	{"day": "2026-10-02", "lang": "de", "page": "calendar", "year": 2026}	{"kind": "tool"}	[]	2	2026-10-02 08:00:00+00	2026-10-02 08:00:10+00	\N	[{"id": "q1", "item": {"kind": "user", "text": "Und morgen?"}, "content": "Und morgen?", "context": {"day": "2026-10-02", "lang": "de", "page": "calendar", "year": 2026}}]
\.


--
-- Data for Name: ai_chat_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ai_chat_items (chat_id, seq, rev, item) FROM stdin;
fpChatIdle0000000001	0	1	{"kind": "user", "text": "Plane Urlaub vom 3. bis 7. August"}
fpChatIdle0000000001	1	2	{"id": "call_1", "args": {"from": "2026-08-03", "to": "2026-08-07"}, "kind": "tool", "name": "add_entries", "status": "ok", "summary": "5 Tage Urlaub"}
fpChatIdle0000000001	2	3	{"kind": "assistant", "text": "Erledigt: 5 Tage Urlaub."}
fpChatRunning0000002	0	1	{"kind": "user", "text": "Wie wird das Wetter?"}
fpChatRunning0000002	1	2	{"id": "call_9", "args": {"query": "Wetter Berlin"}, "kind": "tool", "name": "web_search", "status": "running"}
\.


--
-- Data for Name: ai_chat_messages; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ai_chat_messages (chat_id, seq, message) FROM stdin;
fpChatIdle0000000001	0	{"role": "user", "content": "Plane Urlaub vom 3. bis 7. August"}
fpChatIdle0000000001	1	{"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "add_entries", "arguments": "{}"}}]}
fpChatIdle0000000001	2	{"role": "tool", "content": "ok", "tool_call_id": "call_1"}
fpChatIdle0000000001	3	{"role": "assistant", "content": "Erledigt: 5 Tage Urlaub."}
fpChatRunning0000002	0	{"role": "user", "content": "Wie wird das Wetter?"}
\.


--
-- Data for Name: rate_limits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rate_limits (key, window_start, hits) FROM stdin;
abc	2026-10-01 07:00:00+00	3
\.


--
-- PostgreSQL database dump complete
--
