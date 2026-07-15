export type GoogleSearchInput = {
  query: string;
  language: string;
  country: string;
  limit: number;
};

export async function searchGoogle(_input: GoogleSearchInput): Promise<never> {
  throw new Error("Google search is not implemented in Phase 1.");
}
