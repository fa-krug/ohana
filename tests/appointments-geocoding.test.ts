import { describe, expect, it } from "vitest";
import { parseLocationSuggestions } from "@/lib/appointments/geocoding";
import photon from "./fixtures/appointments/photon_location_suggest.json";

describe("parseLocationSuggestions", () => {
  it("maps Photon features to label + lat/lng (coords are [lng, lat])", () => {
    const out = parseLocationSuggestions(photon as Record<string, unknown>);
    expect(out.length).toBeGreaterThan(0);
    const first = out[0];
    expect(first.label.length).toBeGreaterThan(0);
    expect(Number(first.latitude)).toBeGreaterThan(40); // Germany latitudes ~47-55
    expect(Number(first.longitude)).toBeGreaterThan(5);
  });

  it("skips features without coordinates", () => {
    const out = parseLocationSuggestions({ features: [{ properties: { name: "x" }, geometry: { coordinates: [] } }] });
    expect(out).toHaveLength(0);
  });
});
