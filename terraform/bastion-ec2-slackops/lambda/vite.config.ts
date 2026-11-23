import { defineConfig } from 'vite-plus';

export default defineConfig({
  // 出力の dist/index.mjs は、Terraform の archive_file が zip にする。パスを変えるときは main.tf も直す
  pack: {
    entry: ['src/index.ts'],
    format: 'esm',
    platform: 'node',
    // target は package.json の engines.node（Lambda のランタイムの nodejs24.x）から決まる
    dts: false,
    deps: {
      // AWS SDK はランタイムに、Powertools は AWS が公開する Lambda レイヤーに入っているので、同梱しない
      neverBundle: [/^@aws-sdk\//, /^@aws-lambda-powertools\//],
    },
  },
  lint: {
    ignorePatterns: ['dist/**'],
    rules: {
      curly: ['error', 'all'],
    },
  },
  fmt: {
    singleQuote: true,
    ignorePatterns: ['dist/**'],
  },
  test: {
    include: ['src/**/*.test.ts'],
  },
});
