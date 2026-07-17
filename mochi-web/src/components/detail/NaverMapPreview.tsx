"use client";

import { useEffect, useRef, useState } from "react";
import { MapPin } from "lucide-react";
import { cn } from "@/lib/cn";

interface NaverMapInstance {
  destroy?: () => void;
}

interface NaverMapsNamespace {
  maps: {
    LatLng: new (lat: number, lng: number) => unknown;
    Map: new (element: HTMLElement, options: Record<string, unknown>) => NaverMapInstance;
  };
}

declare global {
  interface Window {
    naver?: NaverMapsNamespace;
  }
}

let sdkPromise: Promise<NaverMapsNamespace> | null = null;

function loadNaverMaps(clientId: string): Promise<NaverMapsNamespace> {
  if (window.naver?.maps) return Promise.resolve(window.naver);
  if (sdkPromise) return sdkPromise;

  const promise = new Promise<NaverMapsNamespace>((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>("script[data-mochi-naver-map]");
    const script = existing ?? document.createElement("script");
    const finish = () => {
      if (window.naver?.maps) resolve(window.naver);
      else reject(new Error("naver_maps_namespace_missing"));
    };
    script.addEventListener("load", finish, { once: true });
    script.addEventListener("error", () => reject(new Error("naver_maps_sdk_failed")), { once: true });
    if (!existing) {
      script.dataset.mochiNaverMap = "true";
      script.async = true;
      script.src = `https://oapi.map.naver.com/openapi/v3/maps.js?ncpKeyId=${encodeURIComponent(clientId)}`;
      document.head.appendChild(script);
    }
  }).catch((error) => {
    sdkPromise = null;
    throw error;
  });
  sdkPromise = promise;
  return promise;
}

export function NaverMapPreview({
  lat,
  lng,
  className,
}: {
  lat: number;
  lng: number;
  className?: string;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const clientId = process.env.NEXT_PUBLIC_NAVER_MAP_CLIENT_ID?.trim();
  const [status, setStatus] = useState<"loading" | "ready" | "failed">(
    clientId ? "loading" : "failed",
  );

  useEffect(() => {
    if (!clientId || !containerRef.current) return;
    let cancelled = false;
    let map: NaverMapInstance | undefined;
    let readinessTimer: number | undefined;
    setStatus("loading");

    void loadNaverMaps(clientId)
      .then((naver) => {
        if (cancelled || !containerRef.current) return;
        const center = new naver.maps.LatLng(lat, lng);
        map = new naver.maps.Map(containerRef.current, {
          center,
          zoom: 16,
          draggable: false,
          scrollWheel: false,
          pinchZoom: false,
          keyboardShortcuts: false,
          disableDoubleTapZoom: true,
          disableDoubleClickZoom: true,
          disableTwoFingerTapZoom: true,
          zoomControl: false,
          scaleControl: false,
        });
        readinessTimer = window.setTimeout(() => {
          if (cancelled) return;
          setStatus(containerRef.current?.childElementCount ? "ready" : "failed");
        }, 800);
      })
      .catch(() => {
        if (!cancelled) setStatus("failed");
      });

    return () => {
      cancelled = true;
      if (readinessTimer !== undefined) window.clearTimeout(readinessTimer);
      map?.destroy?.();
    };
  }, [clientId, lat, lng]);

  return (
    <div className={cn("relative h-full w-full overflow-hidden bg-sky-100", className)}>
      <div ref={containerRef} className="pointer-events-none absolute inset-0" aria-hidden />
      {status === "failed" && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 bg-sky-100 text-[12px] font-semibold text-ink-500">
          <MapPin className="size-5 text-purple-500" aria-hidden />
          네이버 지도에서 위치 보기
        </div>
      )}
      {status === "ready" && (
        <span className="pointer-events-none absolute left-1/2 top-1/2 z-10 flex size-9 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border-[3px] border-white bg-purple-600 shadow-card-lift">
          <MapPin className="size-4 text-white" aria-hidden />
        </span>
      )}
    </div>
  );
}
