"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { MapPin, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { AsyncCombobox } from "@/components/async-combobox";
import { useT } from "@/lib/i18n/provider";
import { setHomeAddressAction } from "@/app/actions/home-address";

export interface HomeAddress {
  address: string | null;
  lat: number | null;
  lng: number | null;
}

/** The family's home address (geocoded with Photon): the origin for distances. */
export function HomeAddressCard({ familyId, home, editor }: { familyId: string; home: HomeAddress; editor: boolean }) {
  const { t } = useT();
  const router = useRouter();
  const [key, setKey] = useState(0); // remounts the combobox after clearing

  async function save(input: { address: string; lat: number | null; lng: number | null }) {
    const res = await setHomeAddressAction(familyId, input);
    if (!res.ok) return void toast.error(res.message);
    toast.success(input.address ? t("homeAddress.saved") : t("homeAddress.cleared"));
    router.refresh();
  }

  return (
    <Card id="home-address" className="scroll-mt-20">
      <CardHeader>
        <CardTitle className="text-lg">{t("homeAddress.title")}</CardTitle>
        <CardDescription>{t("homeAddress.hint")}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {editor ? (
          <div className="flex flex-col gap-2 sm:flex-row">
            <div className="flex-1">
              <AsyncCombobox<{ label: string; latitude: string; longitude: string }>
                key={key}
                endpoint={`/api/v1/families/${familyId}/geocode`}
                getLabel={(i) => i.label}
                initialLabel={home.address ?? ""}
                placeholder={t("homeAddress.placeholder")}
                onSelect={(i) => save({ address: i.label, lat: Number(i.latitude), lng: Number(i.longitude) })}
              />
            </div>
            {home.address && (
              <Button
                variant="outline"
                onClick={async () => {
                  await save({ address: "", lat: null, lng: null });
                  setKey((k) => k + 1);
                }}
              >
                <X className="size-4" /> {t("homeAddress.clear")}
              </Button>
            )}
          </div>
        ) : (
          <p className="text-sm">{home.address ?? <span className="text-muted-foreground">{t("homeAddress.none")}</span>}</p>
        )}
        {home.lat !== null && home.lng !== null && (
          <p className="flex items-center gap-1 text-xs text-muted-foreground">
            <MapPin className="size-3" /> {home.lat.toFixed(5)}, {home.lng.toFixed(5)}
          </p>
        )}
      </CardContent>
    </Card>
  );
}
