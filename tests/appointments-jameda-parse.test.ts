import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { JamedaClient } from "@/lib/appointments/jameda/client";

const client = new JamedaClient(0);
const html = readFileSync("tests/fixtures/appointments/jameda_listing.html", "utf8");
const suchenHtml = readFileSync("tests/fixtures/appointments/jameda_suchen.html", "utf8");
const rangedSlots = JSON.parse(readFileSync("tests/fixtures/appointments/jameda_slots.json", "utf8"));
const nearestSlots = JSON.parse(readFileSync("tests/fixtures/appointments/jameda_slots_nearest.json", "utf8"));

describe("JamedaClient.parseListing", () => {
  it("extracts doctors with identity + addressId from result-item cards", () => {
    const docs = client.parseListing(html);
    expect(docs.length).toBeGreaterThan(0);
    const withCal = docs.filter((d) => d.hasSlots);
    expect(withCal.length).toBeGreaterThan(0);
    const d = docs[0];
    expect(d.doctorId).toMatch(/^\d+$/);
    expect(d.addressId).toMatch(/^\d+$/);
    expect(d.name.trim().length).toBeGreaterThan(0);
    expect(d.bookingUrl).toContain("jameda.de");
    // slug = last path segment of the profile url (city), used only for display/keys context
    expect(d.slug.length).toBeGreaterThan(0);
  });

  it("parses the /suchen search endpoint markup identically", () => {
    const docs = client.parseListing(suchenHtml);
    expect(docs.length).toBeGreaterThan(0);
    expect(docs.some((d) => d.hasSlots)).toBe(true);
    const d = docs[0];
    expect(d.doctorId).toMatch(/^\d+$/);
    expect(d.addressId).toMatch(/^\d+$/);
    expect(d.name.trim().length).toBeGreaterThan(0);
    expect(d.bookingUrl).toContain("jameda.de");
  });

  it("captures per-card coordinates (for cross-source dedup + distance)", () => {
    const docs = client.parseListing(html);
    const withCoords = docs.filter((d) => d.latitude && d.longitude);
    // Coords live in the card body, not the opening tag — most cards carry them.
    expect(withCoords.length).toBeGreaterThan(0);
    expect(withCoords[0].latitude).toMatch(/^-?\d+\.\d+$/);
    expect(withCoords[0].longitude).toMatch(/^-?\d+\.\d+$/);
  });

  it("defaults isOnlineOnly to false when cards are not video-only", () => {
    const docs = client.parseListing(html);
    expect(docs.every((d) => d.isOnlineOnly === false)).toBe(true);
  });
});

describe("JamedaClient.parseSlots", () => {
  it("reads concrete slots from the ranged _items shape (skips booked)", () => {
    const { slots, nextSlot } = client.parseSlots(rangedSlots);
    expect(slots.length).toBeGreaterThan(0);
    expect(slots[0]).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/);
    expect(nextSlot).toBeNull();
  });

  it("reads the nearest-day 'slots' shape", () => {
    const { slots } = client.parseSlots(nearestSlots);
    expect(slots.length).toBeGreaterThan(0);
  });

  it("returns empty for an empty payload", () => {
    expect(client.parseSlots({}).slots).toEqual([]);
  });

  it("excludes booked slots (only free slots are actionable)", () => {
    const { slots } = client.parseSlots({
      _items: [
        { start: "2026-07-14T14:00:00+02:00", booked: true },
        { start: "2026-07-14T14:30:00+02:00", booked: false },
      ],
    });
    expect(slots).toEqual(["2026-07-14T14:30:00+02:00"]);
  });
});

describe("parseListing — landing-page markup (single-quoted value attrs)", () => {
  it("extracts a doctor from a /{slug}/{city} landing card", () => {
    const html = `
      <div data-id="result-item"
           data-result-id='300001'
           data-address-id='addr-900'
           data-doctor-name='Dr. Petra Beispiel'
           data-doctor-url='https://www.jameda.de/berlin/psychiater/dr-petra-beispiel/'
           data-eec-specialization-name='Psychiaterin'
           data-eec-address-cities='Berlin'
           data-eec-has-calendar-with-slots>
        <div class='map' data-lat='52.5200' data-lng='13.4050'></div>
      </div>`;
    const doctors = new JamedaClient(0).parseListing(html);
    expect(doctors).toHaveLength(1);
    const d = doctors[0];
    expect(d.doctorId).toBe("300001");
    expect(d.addressId).toBe("addr-900");
    expect(d.name).toBe("Dr. Petra Beispiel");
    expect(d.slug).toBe("dr-petra-beispiel");
    expect(d.speciality).toBe("Psychiaterin");
    expect(d.city).toBe("Berlin");
    expect(d.latitude).toBe("52.5200");
    expect(d.longitude).toBe("13.4050");
    expect(d.hasSlots).toBe(true);
  });

  it("reads data-is-online-only='true' as isOnlineOnly", () => {
    const onlineHtml = `
      <div data-id="result-item"
           data-result-id='300002'
           data-address-id='addr-901'
           data-doctor-name='Dr. Online Only'
           data-doctor-url='https://www.jameda.de/berlin/psychiater/dr-online-only/'
           data-is-online-only='true'
           data-eec-has-calendar-with-slots></div>`;
    const [d] = new JamedaClient(0).parseListing(onlineHtml);
    expect(d.isOnlineOnly).toBe(true);
  });

  it("treats a missing data-is-online-only as false", () => {
    const plainHtml = `
      <div data-id="result-item"
           data-result-id='300003'
           data-address-id='addr-902'
           data-doctor-name='Dr. In Person'
           data-doctor-url='https://www.jameda.de/berlin/psychiater/dr-in-person/'></div>`;
    const [d] = new JamedaClient(0).parseListing(plainHtml);
    expect(d.isOnlineOnly).toBe(false);
  });
});
