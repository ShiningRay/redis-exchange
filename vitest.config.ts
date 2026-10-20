import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['spec-js/**/*.spec.ts'],
    testTimeout: 20_000,
    hookTimeout: 20_000,
  },
});
