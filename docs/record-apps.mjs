import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RECORDINGS_DIR = path.join(__dirname, 'recordings');

const apps = [
  {
    name: 'task-manager',
    url: 'http://localhost:3000',
    needsLogin: true,
    walkthrough: async (page) => {
      // Already logged in — explore dashboard
      await page.waitForTimeout(2000);
      await slowScroll(page, 3);
      // Try clicking sidebar items
      const navItems = page.locator('nav a, aside a, [role="menuitem"]');
      const count = await navItems.count();
      for (let i = 0; i < Math.min(count, 4); i++) {
        try {
          await navItems.nth(i).click();
          await page.waitForTimeout(1500);
        } catch(e) {}
      }
    }
  },
  {
    name: 'jal-sathi',
    url: 'http://localhost:3008',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 4);
      const navItems = page.locator('nav a, aside a, [role="menuitem"], button:has-text("Dam"), button:has-text("Map")');
      const count = await navItems.count();
      for (let i = 0; i < Math.min(count, 3); i++) {
        try {
          await navItems.nth(i).click();
          await page.waitForTimeout(1500);
        } catch(e) {}
      }
    }
  },
  {
    name: 'tic-tac-toe',
    url: 'http://localhost:3015',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      // Try clicking game cells
      const cells = page.locator('[class*="cell"], [class*="square"], td, [role="button"]');
      const count = await cells.count();
      for (let i = 0; i < Math.min(count, 5); i++) {
        try {
          await cells.nth(i).click();
          await page.waitForTimeout(800);
        } catch(e) {}
      }
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'pet-adoption-hub',
    url: 'http://localhost:3019',
    needsLogin: false,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 4);
      // Try sign up or browse
      try {
        await page.locator('a:has-text("Sign Up"), button:has-text("Sign Up")').first().click();
        await page.waitForTimeout(1500);
      } catch(e) {}
      try {
        await page.locator('a:has-text("Browse"), a:has-text("Pets"), a:has-text("Adopt")').first().click();
        await page.waitForTimeout(2000);
        await slowScroll(page, 2);
      } catch(e) {}
    }
  },
  {
    name: 'savings-vault',
    url: 'http://localhost:3022',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 4);
      const navItems = page.locator('nav a, aside a, [role="menuitem"]');
      const count = await navItems.count();
      for (let i = 0; i < Math.min(count, 4); i++) {
        try {
          await navItems.nth(i).click();
          await page.waitForTimeout(1500);
        } catch(e) {}
      }
    }
  },
  {
    name: 'sre-command-center',
    url: 'http://localhost:3024',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 4);
      const navItems = page.locator('nav a, aside a, [role="menuitem"]');
      const count = await navItems.count();
      for (let i = 0; i < Math.min(count, 4); i++) {
        try {
          await navItems.nth(i).click();
          await page.waitForTimeout(1500);
        } catch(e) {}
      }
    }
  },
  {
    name: 'llm-observability',
    url: 'http://localhost:3026',
    needsLogin: false,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 5);
      // Click hamburger menu or nav items
      try {
        await page.locator('button:has-text("☰"), [class*="hamburger"], nav button').first().click();
        await page.waitForTimeout(1000);
      } catch(e) {}
      const navItems = page.locator('nav a, aside a, [role="menuitem"]');
      const count = await navItems.count();
      for (let i = 0; i < Math.min(count, 4); i++) {
        try {
          await navItems.nth(i).click();
          await page.waitForTimeout(1500);
          await slowScroll(page, 2);
        } catch(e) {}
      }
    }
  }
];

async function slowScroll(page, times = 3) {
  for (let i = 0; i < times; i++) {
    await page.mouse.wheel(0, 300);
    await page.waitForTimeout(600);
  }
}

async function login(page) {
  try {
    // Find and fill email
    const emailInput = page.locator('input[type="email"], input[placeholder*="email"], input[name="email"]').first();
    await emailInput.waitFor({ timeout: 5000 });
    await emailInput.fill('admin@demo.com');
    await page.waitForTimeout(300);

    // Find and fill password
    const passInput = page.locator('input[type="password"]').first();
    await passInput.fill('demo123');
    await page.waitForTimeout(300);

    // Click sign in button
    const signIn = page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Login"), button:has-text("Log in")').first();
    await signIn.click();
    await page.waitForTimeout(3000);
    return true;
  } catch(e) {
    console.log('  Login skipped or failed:', e.message);
    return false;
  }
}

async function recordApp(app) {
  console.log(`\n🎬 Recording: ${app.name}`);
  console.log(`   URL: ${app.url}`);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    recordVideo: {
      dir: RECORDINGS_DIR,
      size: { width: 1920, height: 1080 }
    }
  });

  const page = await context.newPage();

  try {
    await page.goto(app.url, { waitUntil: 'networkidle', timeout: 15000 });
    await page.waitForTimeout(1500);

    if (app.needsLogin) {
      console.log('   Logging in...');
      await login(page);
    }

    console.log('   Walking through app...');
    await app.walkthrough(page);

    // Scroll back to top at end
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
    await page.waitForTimeout(1500);

  } catch(e) {
    console.log(`   ⚠️ Error during recording: ${e.message}`);
  }

  await page.close();
  const video = await page.video()?.path();
  await context.close();
  await browser.close();

  if (video) {
    // Rename to app name
    const { rename } = await import('fs/promises');
    const newPath = path.join(RECORDINGS_DIR, `${app.name}.webm`);
    try {
      await rename(video, newPath);
      console.log(`   ✅ Saved: ${newPath}`);
    } catch(e) {
      console.log(`   ✅ Saved: ${video}`);
    }
  }
}

async function main() {
  console.log('🚀 Spectraal App Recorder');
  console.log(`   Output: ${RECORDINGS_DIR}`);
  console.log(`   Apps: ${apps.length}`);
  console.log('');

  for (const app of apps) {
    try {
      await recordApp(app);
    } catch(e) {
      console.log(`   ❌ Failed: ${e.message}`);
    }
  }

  console.log('\n✅ All recordings complete!');
  console.log(`   Files in: ${RECORDINGS_DIR}`);
}

main().catch(console.error);
