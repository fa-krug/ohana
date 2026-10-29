import { describe, expect, it } from "vitest";
import { criteriaSummary } from "@/lib/appointments/summary";
import type { SearchListItem } from "@/lib/appointments/serialize";

// Minimal translate stub: labels the keys the summary actually uses.
const t = (key: string): string =>
  ({
    "common.dash": "—",
    "appointments.form.sourcesDoctolib": "Doctolib",
    "appointments.form.sourcesJameda": "jameda",
    "appointments.form.insuranceSectorPublic": "Gesetzlich",
    "appointments.form.insuranceSectorPrivate": "Privat",
  })[key] ?? key;

function make(overrides: Partial<SearchListItem>): SearchListItem {
  return {
    id: "s1", name: "S", sources: "doctolib",
    specialitySlug: "", specialityLabel: "",
    jamedaSpecialitySlug: "", jamedaSpecialityLabel: "", jamedaSpecialityType: "leistung",
    jamedaInsuranceType: "", jamedaKidsFriendly: false, jamedaVideo: "any",
    locationLabel: "", latitude: "", longitude: "", insuranceSector: "",
    dayLimit: 14, maxPages: 3, enabled: true, scheduleType: "MINUTES",
    scheduleMinutes: 30, cron: "", notifyOnlyEarlier: false,
    lastRunAt: null, lastStatus: "", nextRunAt: null, runRequested: false, channelIds: [],
    latestRun: null, doctors: [], ignored: [],
    ...overrides,
  };
}

describe("criteriaSummary", () => {
  it("shows only the Doctolib speciality for a doctolib-only search", () => {
    const s = make({ sources: "doctolib", specialityLabel: "Hautarzt", insuranceSector: "public" });
    expect(criteriaSummary(s, t)).toBe("Hautarzt · Gesetzlich");
  });

  it("shows the jameda speciality for a jameda-only search (not the empty Doctolib one)", () => {
    const s = make({ sources: "jameda", jamedaSpecialityLabel: "Kinderarzt" });
    expect(criteriaSummary(s, t)).toBe("Kinderarzt");
  });

  it("lists BOTH source specialities, each labelled, for a both search", () => {
    const s = make({
      sources: "both",
      specialityLabel: "Doctolib Fach",
      jamedaSpecialityLabel: "Jameda Fach",
      insuranceSector: "public",
    });
    expect(criteriaSummary(s, t)).toBe("Doctolib: Doctolib Fach · jameda: Jameda Fach · Gesetzlich");
  });

  it("falls back to the slug when a label is missing", () => {
    const s = make({ sources: "doctolib", specialitySlug: "kinder-jugendpsychiatrie-2" });
    expect(criteriaSummary(s, t)).toBe("kinder-jugendpsychiatrie-2");
  });

  it("appends the location label when present", () => {
    const s = make({ sources: "doctolib", specialityLabel: "Hautarzt", locationLabel: "Berlin" });
    expect(criteriaSummary(s, t)).toBe("Hautarzt · Berlin");
  });

  it("shows a dash when no source is active", () => {
    const s = make({ sources: "none" });
    expect(criteriaSummary(s, t)).toBe("—");
  });
});
