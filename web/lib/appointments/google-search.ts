// Build a Google search URL from free-text parts (doctor name, title, address).

export function googleSearchUrl(parts: (string | null | undefined)[]): string {
  const q = parts.map((p) => (p ?? "").trim()).filter(Boolean).join(" ");
  return `https://www.google.com/search?q=${encodeURIComponent(q)}`;
}
