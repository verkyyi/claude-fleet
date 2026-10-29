import { useEffect, useRef } from "react";
import QRCode from "qrcode";

// Encode the real link locally. No page content or URL goes to a QR service.
export function PageQR({ url }: { url: string }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (canvas.current) void QRCode.toCanvas(canvas.current, url, { width: 144, margin: 2 });
  }, [url]);
  return <canvas ref={canvas} aria-label="活页链接二维码" role="img" className="rounded-lg border" />;
}
