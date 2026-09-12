/** Briefly tool failures preserve the app's code. SDK failures use their own descriptive codes. */
export class BrieflyError extends Error {
  readonly code: string;

  constructor(code: string, message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "BrieflyError";
    this.code = code;
  }
}
