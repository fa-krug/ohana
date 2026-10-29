// Great-circle distance between two lat/lng points, and locale-aware formatting.

export function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371; // Earth radius in km
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

export function formatDistanceKm(km: number, locale: string): string {
  const digits = km < 10 ? 1 : 0;
  const n = km.toLocaleString(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return `${n} km`;
}
