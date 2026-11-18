// Asked to read a vaccination / check-up booklet (the health scan prompt), it answers with JSON:
// U1 on the birthday, U2 four days later (twice), vac-2m with an unreadable date, tetanus on
// 2019-05-03, a flu shot in the future and an unknown code "u99". Without a picture it refuses
// like the transcription.

import { type Msg, refusesWithoutImage, reply } from "./reply";

/** The health scan prompt: a few records around the birthday (see the top). */
export function healthScan(stream: boolean, system: string, message: Msg) {
  const refused = refusesWithoutImage(message);
  if (refused) return refused;
  const born = /born (\d{4}-\d{2}-\d{2})/.exec(system)?.[1] ?? "2020-01-01";
  const plus = (days: number) => new Date(Date.parse(`${born}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);
  const records = [
    { code: "u1", day: born, note: "" },
    { code: "U2", day: plus(4), note: "Stempel Dr. Weiß" },
    { code: "u2", day: plus(5), note: "" },
    { code: "vac-2m", day: "15.??.20", note: "Vaxelis" },
    { code: "td", day: "2019-05-03", note: "Boostrix" },
    { code: "flu", day: "2999-10-01", note: "" },
    { code: "u99", day: born, note: "" },
  ];
  return reply(stream, "```json\n" + JSON.stringify({ records }) + "\n```");
}
