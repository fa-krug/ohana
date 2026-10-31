"use server";

import { revalidatePath } from "next/cache";
import { run } from "@/lib/actions/result";
import { homeAddressSchema, setHomeAddress } from "@/lib/families/home";

export const setHomeAddressAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    setHomeAddress(db, { id: user.id }, familyId, homeAddressSchema.parse(input), now);
    revalidatePath(`/f/${familyId}`, "layout");
  });
