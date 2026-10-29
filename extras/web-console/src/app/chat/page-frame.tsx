// The same sandbox for conversation cards and the studio canvas.
export function PageFrame({ src, title, className }: { src: string; title: string; className?: string }) {
  return <iframe src={src} title={title} referrerPolicy="no-referrer" loading="lazy"
    sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox" className={className} />;
}
