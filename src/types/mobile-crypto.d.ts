declare module "browserify-aes/browser" {
  export const createCipheriv: typeof import("node:crypto").createCipheriv;
  export const createDecipheriv: typeof import("node:crypto").createDecipheriv;
}

declare module "create-hash/browser" {
  const createHash: typeof import("node:crypto").createHash;
  export default createHash;
}

declare module "create-hmac/browser" {
  const createHmac: typeof import("node:crypto").createHmac;
  export default createHmac;
}

declare module "public-encrypt/publicEncrypt" {
  const publicEncrypt: typeof import("node:crypto").publicEncrypt;
  export default publicEncrypt;
}

declare module "randombytes/browser" {
  const randomBytes: typeof import("node:crypto").randomBytes;
  export default randomBytes;
}
