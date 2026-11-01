import { describe, expect, it } from "vitest";
import { parseLocationSuggestions, suggestionLabel } from "@/lib/appointments/geocoding";
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

describe("suggestionLabel", () => {
  it("keeps the house number with the street", () => {
    expect(suggestionLabel({ street: "Hauptstraße", housenumber: "5a", postcode: "12345", city: "Berlin" })).toBe(
      "Hauptstraße 5a, 12345 Berlin",
    );
  });

  it("leaves out a name that only repeats the street, keeps a real one", () => {
    expect(suggestionLabel({ name: "Hauptstraße", street: "Hauptstraße", postcode: "12345", city: "Berlin" })).toBe(
      "Hauptstraße, 12345 Berlin",
    );
    expect(
      suggestionLabel({ name: "Praxis Dr. Meier", street: "Hauptstraße", housenumber: "5", postcode: "12345", city: "Berlin" }),
    ).toBe("Praxis Dr. Meier, Hauptstraße 5, 12345 Berlin");
  });

  it("works with a place alone", () => {
    expect(suggestionLabel({ name: "Berlin", city: "Berlin" })).toBe("Berlin");
    expect(suggestionLabel({ postcode: "12345" })).toBe("12345");
  });
});
