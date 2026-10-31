// family-planner's tests/csv.test.ts: bank statement CSV parsing and money parsing.

import { describe, expect, it } from "vitest";
import {
  decode,
  detectDateFormat,
  detectDelimiter,
  guessMapping,
  mapRows,
  parseCsv,
  parseDate,
  tableOf,
} from "@/lib/finance/csv";
import { centsToInput, parseMoney } from "@/lib/finance/money";

function assertEquals(actual: unknown, expected: unknown, message?: string) {
  expect(actual, message).toEqual(expected);
}

describe("bank statement CSV", () => {
it("parses amounts as typed or exported", () => {
  const cases: [string, number | null][] = [
    ["12", 1200],
    ["12.5", 1250],
    ["12,50", 1250],
    ["-1.234,56", -123456],
    ["1,234.56", 123456],
    ["-3,20 €", -320],
    ["€ 1 234,00", 123400],
    ["(45.00)", -4500],
    ["12,50-", -1250],
    ["+7", 700],
    ["1.234", 123400], // thousands, no decimals
    ["abc", null],
    ["", null],
  ];
  for (const [input, cents] of cases) assertEquals(parseMoney(input), cents, input);
  assertEquals(parseMoney("1.234", "."), null); // three decimals
  assertEquals(parseMoney("1,5", ","), 150);
  assertEquals(centsToInput(-123456, "de"), "1234,56");
  assertEquals(centsToInput(5, "en"), "0.05");
});

it("splits CSV with quotes, escaped quotes and newlines in cells", () => {
  const text = 'a;"b;c";"say ""hi"""\r\n1;"two\nlines";3\n\n';
  assertEquals(parseCsv(text, ";"), [["a", "b;c", 'say "hi"'], ["1", "two\nlines", "3"]]);
  assertEquals(detectDelimiter("a,b,c\n1,2,3\n4,5,6"), ",");
  assertEquals(detectDelimiter("a;b;c\n1,5;2;3\n4;5,5;6"), ";");
  assertEquals(detectDelimiter("a\tb\n1\t2"), "\t");
});

it("reads dates in the common bank formats", () => {
  assertEquals(parseDate("31.12.2026", "DD.MM.YYYY"), "2026-12-31");
  assertEquals(parseDate("1.2.26", "DD.MM.YY"), "2026-02-01");
  assertEquals(parseDate("2026-02-30", "YYYY-MM-DD"), null);
  assertEquals(parseDate("12/31/2026", "MM/DD/YYYY"), "2026-12-31");
  assertEquals(detectDateFormat(["01.03.2026", "15.03.2026"]), "DD.MM.YYYY");
  assertEquals(detectDateFormat(["03/04/2026", "03/25/2026"]), "MM/DD/YYYY");
  assertEquals(detectDateFormat(["03/04/2026", "25/03/2026"]), "DD/MM/YYYY");
  assertEquals(detectDateFormat(["x"]), null);
});

it("decodes UTF-8 and falls back to Windows-1252", () => {
  assertEquals(decode(new TextEncoder().encode("﻿Empfänger")).text, "Empfänger");
  const latin = new Uint8Array([0x45, 0x6d, 0x70, 0x66, 0xe4, 0x6e, 0x67, 0x65, 0x72]);
  assertEquals(decode(latin), { text: "Empfänger", encoding: "windows-1252" });
});

it("maps a German bank export with a preamble", () => {
  const text = [
    '"Kontonummer:";"DE12 3456";',
    '"Zeitraum:";"01.03.2026 - 31.03.2026";',
    "",
    '"Buchungstag";"Valuta";"Auftraggeber/Empfänger";"Verwendungszweck";"Betrag (EUR)"',
    '"02.03.2026";"02.03.2026";"REWE Markt";"Einkauf Karte";"-45,99"',
    '"03.03.2026";"03.03.2026";"Arbeitgeber GmbH";"Gehalt März";"3.250,00"',
    '"04.03.2026";"04.03.2026";"Stadtwerke";"Abschlag";"-89,00"',
  ].join("\n");
  const m = guessMapping(text, "utf-8");
  assertEquals(
    [m.delimiter, m.skipRows, m.hasHeader, m.date, m.dateFormat, m.amount, m.payee],
    [";", 2, true, 0, "DD.MM.YYYY", 4, 2],
  );
  assertEquals([m.description, m.decimal], [[3], ","]);
  const { header, rows } = tableOf(text, m);
  assertEquals(header[0], "Buchungstag");
  const { ok, errors } = mapRows(rows, m);
  assertEquals(errors, []);
  assertEquals(ok.map((r) => [r.date, r.amountCents, r.payee, r.description]), [
    ["2026-03-02", -4599, "REWE Markt", "Einkauf Karte"],
    ["2026-03-03", 325000, "Arbeitgeber GmbH", "Gehalt März"],
    ["2026-03-04", -8900, "Stadtwerke", "Abschlag"],
  ]);
});

it("maps debit / credit columns and English formats", () => {
  const text = [
    "Date,Description,Debit,Credit,Balance",
    "03/01/2026,Coffee shop,3.50,,996.50",
    "03/02/2026,Paycheck,,2000.00,2996.50",
    "03/15/2026,Rent,1200.00,,1796.50",
  ].join("\n");
  const m = guessMapping(text, "utf-8");
  assertEquals([m.delimiter, m.dateFormat, m.amount, m.debit, m.credit], [
    ",",
    "MM/DD/YYYY",
    null,
    2,
    3,
  ]);
  const { ok } = mapRows(tableOf(text, m).rows, { ...m, payee: null, description: [1] });
  assertEquals(ok.map((r) => [r.date, r.amountCents, r.description]), [
    ["2026-03-01", -350, "Coffee shop"],
    ["2026-03-02", 200000, "Paycheck"],
    ["2026-03-15", -120000, "Rent"],
  ]);
});

it("reports rows that don't parse", () => {
  const good = Array.from({ length: 8 }, (_, i) => `0${i + 1}.03.2026;-${i + 1},00;ok`);
  const text = ["Datum;Betrag;Text", ...good, "kein Datum;-2,00;x", "10.03.2026;abc;y"].join("\n");
  const m = guessMapping(text, "utf-8");
  assertEquals([m.date, m.amount], [0, 1]);
  const { ok, errors } = mapRows(tableOf(text, m).rows, m);
  assertEquals(ok.length, 8);
  assertEquals(errors, [{ line: 8, reason: "date" }, { line: 9, reason: "amount" }]);
});
});
