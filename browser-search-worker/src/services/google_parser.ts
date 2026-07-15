export type ParsedGoogleResult = {
  position: number;
  title: string;
  url: string;
  content: string;
};

export function parseGoogleResults(_html: string): ParsedGoogleResult[] {
  throw new Error("Google parser is not implemented in Phase 1.");
}
