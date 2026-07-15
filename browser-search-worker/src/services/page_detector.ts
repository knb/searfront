export type PageDetection = {
  captcha: boolean;
  consentPage: boolean;
  rateLimited: boolean;
};

export function detectPageState(_html: string, _url: string): PageDetection {
  return {
    captcha: false,
    consentPage: false,
    rateLimited: false,
  };
}
