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
-- Data for Name: finance_categories; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.finance_categories (family_id, id, name, color, icon, kind, "position", parent_id) FROM stdin;
fpKrugFamily00000001	groceries	Lebensmittel	#22c55e	🛒	expense	0	\N
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
