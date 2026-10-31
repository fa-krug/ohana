"use server";

import { revalidatePath } from "next/cache";
import { run } from "@/lib/actions/result";
import { searchInputSchema } from "@/lib/appointments/schema";
import { type BookingInput, bookSlot, removeBooking } from "@/lib/appointments/booking";
import {
  createSearch,
  deleteSearch,
  ignoreResult,
  requestRun,
  unignoreEntry,
  updateSearch,
} from "@/lib/appointments/searches";

function refresh(familyId: string) {
  revalidatePath(`/f/${familyId}/appointments`, "layout");
}

export const createSearchAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    const res = createSearch(db, { id: user.id }, familyId, searchInputSchema.parse(input), now);
    refresh(familyId);
    return res;
  });

export const updateSearchAction = async (familyId: string, searchId: string, input: unknown) =>
  run(({ db, user, now }) => {
    updateSearch(db, { id: user.id }, familyId, searchId, searchInputSchema.parse(input), now);
    refresh(familyId);
  });

export const deleteSearchAction = async (familyId: string, searchId: string) =>
  run(({ db, user }) => {
    deleteSearch(db, { id: user.id }, familyId, searchId);
    refresh(familyId);
  });

/** Queues the search for the worker (it runs within APPT_TICK_SECONDS); never scrapes here. */
export const runSearchNowAction = async (familyId: string, searchId: string) =>
  run(({ db, user, now }) => {
    requestRun(db, { id: user.id }, familyId, searchId, now);
    refresh(familyId);
  });

export const ignoreResultAction = async (familyId: string, resultId: number) =>
  run(({ db, user, now }) => {
    const res = ignoreResult(db, { id: user.id }, familyId, resultId, now);
    refresh(familyId);
    return res;
  });

export const unignoreEntryAction = async (familyId: string, entryId: number) =>
  run(({ db, user }) => {
    unignoreEntry(db, { id: user.id }, familyId, entryId);
    refresh(familyId);
  });

/** Marks a slot as booked: a calendar event (phase 7); optionally stops the search. */
export const bookSlotAction = async (familyId: string, searchId: string, resultId: number, input: unknown) =>
  run(({ db, user, now }) => {
    const event = bookSlot(db, { id: user.id }, familyId, searchId, resultId, input as BookingInput, now);
    refresh(familyId);
    revalidatePath(`/f/${familyId}`);
    return { eventId: event.id };
  });

/** Removes a booked appointment from the calendar (not from the practice's books). */
export const removeBookingAction = async (familyId: string, eventId: string) =>
  run(({ db, user }) => {
    removeBooking(db, { id: user.id }, familyId, eventId);
    refresh(familyId);
    revalidatePath(`/f/${familyId}`);
  });
