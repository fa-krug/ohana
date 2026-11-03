// The members' colors: every account and person of a family has one of a fixed palette (by
// key), and the calendar's entry types take theirs: a member's first type of a year the color
// itself, each further one a shade of it (typeShade). Browser-safe.

/** The palette, in the order new members get its colors. */
export const MEMBER_COLORS = [
  { key: "blue", hex: "#0090ff" },
  { key: "orange", hex: "#f76b15" },
  { key: "green", hex: "#30a46c" },
  { key: "red", hex: "#e5484d" },
  { key: "purple", hex: "#8e4ec6" },
  { key: "yellow", hex: "#f2b705" },
  { key: "teal", hex: "#12a594" },
  { key: "pink", hex: "#d6409f" },
  { key: "indigo", hex: "#3e63dd" },
  { key: "brown", hex: "#8a5a3c" },
] as const;

export type MemberColor = (typeof MEMBER_COLORS)[number]["key"];

/** The base of the types that belong to nobody. */
export const NEUTRAL_COLOR = "#8e8e93";

export function isMemberColor(v: unknown): v is MemberColor {
  return MEMBER_COLORS.some((c) => c.key === v);
}

/** The hex of a palette key; the neutral color for anything else. */
export function memberColorHex(key: string | null | undefined): string {
  return MEMBER_COLORS.find((c) => c.key === key)?.hex ?? NEUTRAL_COLOR;
}

/** A new member's color: the first not `used` yet, else the least used (ties: palette order). */
export function pickMemberColor(used: string[]): MemberColor {
  const counts = new Map<string, number>();
  for (const k of used) counts.set(k, (counts.get(k) ?? 0) + 1);
  let best: MemberColor = MEMBER_COLORS[0].key;
  let bestCount = Infinity;
  for (const { key } of MEMBER_COLORS) {
    const n = counts.get(key) ?? 0;
    if (n < bestCount) [best, bestCount] = [key, n];
  }
  return best;
}

// Lightness steps of the shades, by index % 12 (index 0: the base itself).
const LIGHTNESS = [0, 0.15, -0.13, 0.27, -0.23, 0.07, -0.06, 0.21, -0.18, 0.33, -0.28, 0.11];

/** The `index`th shade of `baseHex` (0 = the base): its lightness moved by a step; from 12 on
 *  also its hue, 10° more each round of 12, the sign alternating by round. "#rrggbb". */
export function typeShade(baseHex: string, index: number): string {
  if (index <= 0) return baseHex.toLowerCase();
  const [h, s, l] = toHsl(baseHex);
  const round = Math.ceil(index / 12);
  const hue = index >= 12 ? h + 10 * round * (round % 2 === 1 ? 1 : -1) : h;
  const light = Math.min(0.88, Math.max(0.15, l + LIGHTNESS[index % 12]));
  return toHex(((hue % 360) + 360) % 360, s, light);
}

function toHsl(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => v / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h * 60, s, l];
}

function toHex(h: number, s: number, l: number): string {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const [r, g, b] =
    h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return `#${[r, g, b].map((v) => Math.round((v + m) * 255).toString(16).padStart(2, "0")).join("")}`;
}
