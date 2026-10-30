// Birthdays of family members ("YYYY-MM-DD"); browser-safe (the settings show the age, the
// calendar the birthdays of its year).

/** Full years on `today` ("YYYY-MM-DD"). */
export function ageOn(birthday: string, today: string): number {
  const years = Number(today.slice(0, 4)) - Number(birthday.slice(0, 4));
  return today.slice(5) < birthday.slice(5) ? years - 1 : years;
}

export interface BirthdayDay {
  day: string;
  name: string;
  /** The age they turn that day. */
  age: number;
}

const isLeap = (y: number) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

/** The birthdays from `from` to `to` (inclusive, at most 10 years), by day then name; 29 Feb
 *  falls on 28 Feb in other years. Nothing before someone's birth. */
export function birthdaysIn(
  people: { name: string; birthday: string | null }[],
  from: string,
  to: string,
): BirthdayDay[] {
  const first = Number(from.slice(0, 4));
  const last = Math.min(Number(to.slice(0, 4)), first + 9);
  const out: BirthdayDay[] = [];
  for (const p of people) {
    if (!p.birthday) continue;
    const born = Number(p.birthday.slice(0, 4));
    for (let y = Math.max(first, born + 1); y <= last; y++) {
      const md = p.birthday.slice(5) === "02-29" && !isLeap(y) ? "02-28" : p.birthday.slice(5);
      const day = `${y}-${md}`;
      if (day >= from && day <= to) out.push({ day, name: p.name, age: y - born });
    }
  }
  return out.sort((a, b) => a.day.localeCompare(b.day) || a.name.localeCompare(b.name));
}
