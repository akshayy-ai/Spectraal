import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { statSync } from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RECORDINGS_DIR = path.join(__dirname, 'recordings');

async function main() {
  console.log('🍔 Recording FoodDash — Full Walkthrough');

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    recordVideo: {
      dir: RECORDINGS_DIR,
      size: { width: 1920, height: 1080 }
    }
  });

  const page = await context.newPage();

  // ── Login ──────────────────────────────────────
  console.log('   Logging in...');
  await page.goto('http://localhost:3030', { waitUntil: 'networkidle', timeout: 15000 });
  await page.waitForTimeout(2000);

  await page.locator('input[type="email"]').first().fill('admin@demo.com');
  await page.waitForTimeout(400);
  await page.locator('input[type="password"]').first().fill('demo123');
  await page.waitForTimeout(400);
  await page.locator('button[type="submit"]').first().click();
  await page.waitForTimeout(3000);

  // ── Dashboard ──────────────────────────────────
  console.log('   Dashboard overview...');
  await page.waitForTimeout(1500);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1500);

  // ── Restaurants ────────────────────────────────
  console.log('   Browsing restaurants...');
  // Open hamburger menu
  try {
    const menuBtn = page.locator('button:has-text("Menu"), button[aria-label*="menu"], nav button').first();
    await menuBtn.click();
    await page.waitForTimeout(1000);
  } catch(e) {}

  // Click Restaurants nav
  try {
    await page.locator('a[href="/restaurants"]').first().click();
  } catch(e) {
    await page.goto('http://localhost:3030/restaurants', { waitUntil: 'networkidle', timeout: 10000 });
  }
  await page.waitForTimeout(2500);

  // Scroll through restaurant list
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1000);

  // Try category filters
  console.log('   Trying category filters...');
  const categories = ['American', 'Italian', 'Bakery', 'Mexican', 'Japanese'];
  for (const cat of categories) {
    try {
      const btn = page.locator(`button:has-text("${cat}"), [role="tab"]:has-text("${cat}")`).first();
      await btn.click({ timeout: 2000 });
      await page.waitForTimeout(1200);
    } catch(e) {}
  }
  // Back to All
  try {
    await page.locator('button:has-text("All")').first().click();
    await page.waitForTimeout(1000);
  } catch(e) {}

  // Try search
  console.log('   Searching restaurants...');
  try {
    const searchInput = page.locator('input[placeholder*="Search"], input[type="search"]').first();
    await searchInput.click();
    await page.waitForTimeout(500);
    await searchInput.fill('Pizza');
    await page.waitForTimeout(1500);
    await searchInput.fill('');
    await page.waitForTimeout(1000);
  } catch(e) {}

  // Click on first restaurant card to see menu
  console.log('   Opening restaurant menu...');
  try {
    const card = page.locator('[class*="card"], [class*="restaurant"], a[href*="/restaurants/"]').first();
    await card.click();
    await page.waitForTimeout(2500);

    // Scroll through menu items
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(800);
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(800);
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(800);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
    await page.waitForTimeout(1000);

    // Try adding items to cart
    console.log('   Adding items to cart...');
    const addBtns = page.locator('button:has-text("Add"), button:has-text("add"), button:has-text("+")');
    const addCount = await addBtns.count();
    for (let i = 0; i < Math.min(addCount, 3); i++) {
      try {
        await addBtns.nth(i).click();
        await page.waitForTimeout(1200);
      } catch(e) {}
    }
    await page.waitForTimeout(1500);
  } catch(e) {
    console.log('   Could not open restaurant detail');
  }

  // ── Cart ───────────────────────────────────────
  console.log('   Checking cart...');
  try {
    await page.locator('a[href="/cart"]').first().click();
  } catch(e) {
    await page.goto('http://localhost:3030/cart', { waitUntil: 'networkidle', timeout: 10000 });
  }
  await page.waitForTimeout(2500);
  await page.mouse.wheel(0, 300);
  await page.waitForTimeout(800);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1000);

  // Try quantity controls if present
  try {
    const plusBtn = page.locator('button:has-text("+")').first();
    await plusBtn.click();
    await page.waitForTimeout(800);
    await plusBtn.click();
    await page.waitForTimeout(800);
  } catch(e) {}

  // ── Orders ─────────────────────────────────────
  console.log('   Checking order history...');
  // Open menu
  try {
    const menuBtn = page.locator('button:has-text("Menu"), button[aria-label*="menu"], nav button').first();
    await menuBtn.click();
    await page.waitForTimeout(1000);
  } catch(e) {}

  try {
    await page.locator('a[href="/orders"]').first().click();
  } catch(e) {
    await page.goto('http://localhost:3030/orders', { waitUntil: 'networkidle', timeout: 10000 });
  }
  await page.waitForTimeout(2500);

  // Scroll through orders
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1000);

  // Try order status filters
  try {
    await page.locator('button:has-text("Delivered")').first().click();
    await page.waitForTimeout(1500);
    await page.locator('button:has-text("Cancelled")').first().click();
    await page.waitForTimeout(1500);
    await page.locator('button:has-text("All")').first().click();
    await page.waitForTimeout(1000);
  } catch(e) {}

  // Click on an order to see details
  try {
    const orderCard = page.locator('[class*="card"], [class*="order"]').first();
    await orderCard.click();
    await page.waitForTimeout(2500);
    await page.mouse.wheel(0, 300);
    await page.waitForTimeout(800);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
    await page.waitForTimeout(1000);
  } catch(e) {}

  // ── Admin ──────────────────────────────────────
  console.log('   Checking admin panel...');
  // Open menu
  try {
    const menuBtn = page.locator('button:has-text("Menu"), button[aria-label*="menu"], nav button').first();
    await menuBtn.click();
    await page.waitForTimeout(1000);
  } catch(e) {}

  try {
    await page.locator('a[href="/admin/restaurants"], a[href*="admin"]').first().click();
  } catch(e) {
    await page.goto('http://localhost:3030/admin/restaurants', { waitUntil: 'networkidle', timeout: 10000 });
  }
  await page.waitForTimeout(2500);

  // Scroll through admin data
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(800);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1500);

  // ── Back to Dashboard ──────────────────────────
  console.log('   Returning to dashboard...');
  try {
    const menuBtn = page.locator('button:has-text("Menu"), button[aria-label*="menu"], nav button').first();
    await menuBtn.click();
    await page.waitForTimeout(1000);
    await page.locator('a[href="/dashboard"]').first().click();
  } catch(e) {
    await page.goto('http://localhost:3030/dashboard', { waitUntil: 'networkidle', timeout: 10000 });
  }
  await page.waitForTimeout(2000);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(2000);

  // ── Save ───────────────────────────────────────
  await page.close();
  const video = await page.video()?.path();
  await context.close();
  await browser.close();

  if (video) {
    const { rename } = await import('fs/promises');
    const webmPath = path.join(RECORDINGS_DIR, 'fooddash.webm');
    await rename(video, webmPath);

    const mp4Path = path.join(RECORDINGS_DIR, 'fooddash.mp4');
    execSync(`ffmpeg -y -i "${webmPath}" -c:v libx264 -preset fast -crf 22 -pix_fmt yuv420p -movflags +faststart "${mp4Path}" 2>/dev/null`);
    const size = (statSync(mp4Path).size / (1024 * 1024)).toFixed(1);
    console.log(`\n   ✅ fooddash.mp4 (${size}MB)`);
  }
}

main().catch(console.error);
