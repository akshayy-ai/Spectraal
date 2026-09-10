import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RECORDINGS_DIR = path.join(__dirname, 'recordings');

// ── Helpers ──────────────────────────────────────────────

async function slowScroll(page, times = 3, delay = 700) {
  for (let i = 0; i < times; i++) {
    await page.mouse.wheel(0, 350);
    await page.waitForTimeout(delay);
  }
}

async function scrollToTop(page) {
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(800);
}

async function login(page) {
  try {
    const emailInput = page.locator('input[type="email"], input[placeholder*="email"], input[name="email"]').first();
    await emailInput.waitFor({ timeout: 5000 });
    await emailInput.click();
    await page.waitForTimeout(300);
    await emailInput.fill('admin@demo.com');
    await page.waitForTimeout(500);
    const passInput = page.locator('input[type="password"]').first();
    await passInput.click();
    await page.waitForTimeout(300);
    await passInput.fill('demo123');
    await page.waitForTimeout(500);
    const signIn = page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Login"), button:has-text("Log in")').first();
    await signIn.click();
    await page.waitForTimeout(3000);
    return true;
  } catch (e) {
    console.log('    Login skipped:', e.message.slice(0, 80));
    return false;
  }
}

async function clickAllNavItems(page, maxItems = 10) {
  // Try multiple nav selectors
  const selectors = [
    'aside a',
    'nav a[href]',
    '[role="menuitem"]',
    'aside button',
    '.sidebar a',
    '.nav-link',
    '[class*="sidebar"] a',
    '[class*="menu"] a[href]',
  ];

  const visited = new Set();

  for (const selector of selectors) {
    const items = page.locator(selector);
    const count = await items.count();
    if (count < 2) continue;

    for (let i = 0; i < Math.min(count, maxItems); i++) {
      try {
        const item = items.nth(i);
        const text = await item.textContent().catch(() => '');
        const href = await item.getAttribute('href').catch(() => '');
        const key = text?.trim() + href;

        // Skip logout, sign out, external links
        if (!key || visited.has(key)) continue;
        if (/logout|sign.?out|external/i.test(key)) continue;
        visited.add(key);

        await item.click();
        await page.waitForTimeout(2000);
        await slowScroll(page, 3, 500);
        await scrollToTop(page);
        await page.waitForTimeout(500);
      } catch (e) {}
    }
    if (visited.size >= 3) break; // found working nav
  }

  // Also try hamburger menu on mobile-style layouts
  if (visited.size === 0) {
    try {
      const hamburger = page.locator('button:has(svg), [class*="hamburger"], [class*="menu-toggle"], button[aria-label*="menu"]').first();
      await hamburger.click();
      await page.waitForTimeout(1000);
      // Now try nav items again
      for (const selector of selectors) {
        const items = page.locator(selector);
        const count = await items.count();
        for (let i = 0; i < Math.min(count, 6); i++) {
          try {
            await items.nth(i).click();
            await page.waitForTimeout(2000);
            await slowScroll(page, 2, 500);
            await scrollToTop(page);
          } catch (e) {}
        }
        if (count > 1) break;
      }
    } catch (e) {}
  }
}

// ── App Definitions ──────────────────────────────────────

const apps = [
  {
    name: 'task-manager',
    url: 'http://localhost:3000',
    needsLogin: true,
    walkthrough: async (page) => {
      // Dashboard overview
      await page.waitForTimeout(2000);
      await slowScroll(page, 4);
      await scrollToTop(page);

      // Navigate all pages
      await clickAllNavItems(page);

      // Try creating a task
      try {
        const addBtn = page.locator('button:has-text("Add"), button:has-text("Create"), button:has-text("New")').first();
        await addBtn.click();
        await page.waitForTimeout(1500);
        // Fill form if modal appeared
        const titleInput = page.locator('input[name="title"], input[placeholder*="title"], input[placeholder*="Task"]').first();
        await titleInput.fill('Demo task from Spectraal');
        await page.waitForTimeout(500);
        const saveBtn = page.locator('button[type="submit"], button:has-text("Save"), button:has-text("Create")').first();
        await saveBtn.click();
        await page.waitForTimeout(2000);
      } catch (e) {}

      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'jal-sathi',
    url: 'http://localhost:3008',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 5);
      await scrollToTop(page);
      await clickAllNavItems(page);
      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'tic-tac-toe',
    url: 'http://localhost:3015',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);

      // Find the game board - try multiple strategies
      // Strategy 1: Click grid cells by various selectors
      const cellSelectors = [
        '[class*="cell"]',
        '[class*="square"]',
        '[class*="board"] button',
        '[class*="board"] div[role="button"]',
        '[class*="grid"] button',
        '[class*="grid"] > div',
        'table td',
        '[class*="game"] button',
      ];

      let cells = null;
      for (const sel of cellSelectors) {
        const found = page.locator(sel);
        const count = await found.count();
        if (count >= 9) {
          cells = found;
          console.log(`    Found ${count} cells with: ${sel}`);
          break;
        }
      }

      if (cells) {
        // Play a game — click cells in a pattern
        // X goes first: 0, then AI/O responds, then X: 4, etc.
        const moves = [0, 1, 4, 2, 8, 3, 6, 5, 7]; // Try all cells
        for (const move of moves) {
          try {
            const cell = cells.nth(move);
            const text = await cell.textContent().catch(() => '');
            // Only click empty cells
            if (!text || text.trim() === '') {
              await cell.click();
              await page.waitForTimeout(1200);
            }
          } catch (e) {}
        }
        await page.waitForTimeout(2000);

        // Look for "Play Again" or "New Game" button
        try {
          const playAgain = page.locator('button:has-text("Play Again"), button:has-text("New Game"), button:has-text("Restart"), button:has-text("Reset")').first();
          await playAgain.click();
          await page.waitForTimeout(1500);

          // Play another quick game
          for (const move of [4, 0, 2, 6, 1, 3]) {
            try {
              const cell = cells.nth(move);
              const text = await cell.textContent().catch(() => '');
              if (!text || text.trim() === '') {
                await cell.click();
                await page.waitForTimeout(1000);
              }
            } catch (e) {}
          }
          await page.waitForTimeout(2000);
        } catch (e) {}
      } else {
        console.log('    Could not find game cells, exploring pages...');
        await slowScroll(page, 3);
      }

      // Check nav for leaderboard, history, etc.
      await clickAllNavItems(page, 5);
      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'pet-adoption-hub',
    url: 'http://localhost:3019',
    needsLogin: false,
    walkthrough: async (page) => {
      // Landing page scroll
      await page.waitForTimeout(2000);
      await slowScroll(page, 6, 600);
      await scrollToTop(page);
      await page.waitForTimeout(1000);

      // Sign up
      try {
        await page.locator('a:has-text("Sign Up"), button:has-text("Sign Up"), a:has-text("Register")').first().click();
        await page.waitForTimeout(2000);
        await scrollToTop(page);
      } catch (e) {}

      // Go to login and log in
      try {
        await page.locator('a:has-text("Log In"), a:has-text("Sign In"), a:has-text("Login")').first().click();
        await page.waitForTimeout(1500);
        await login(page);
      } catch (e) {}

      // Navigate all pages
      await clickAllNavItems(page);

      // Try browsing pets
      try {
        await page.locator('a:has-text("Browse"), a:has-text("Pets"), a:has-text("Adopt"), a:has-text("Animals")').first().click();
        await page.waitForTimeout(2000);
        await slowScroll(page, 3);

        // Click on a pet card
        const card = page.locator('[class*="card"], [class*="pet"]').first();
        await card.click();
        await page.waitForTimeout(2000);
        await slowScroll(page, 2);
      } catch (e) {}

      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'savings-vault',
    url: 'http://localhost:3022',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 5);
      await scrollToTop(page);

      // Navigate all pages
      await clickAllNavItems(page);

      // Try adding a transaction
      try {
        const addBtn = page.locator('button:has-text("Add"), button:has-text("New"), button:has-text("Deposit"), button:has-text("Transfer")').first();
        await addBtn.click();
        await page.waitForTimeout(2000);
        // Close modal if opened
        try {
          await page.locator('button:has-text("Cancel"), button:has-text("Close"), [aria-label="Close"]').first().click();
          await page.waitForTimeout(1000);
        } catch(e) {}
      } catch (e) {}

      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'sre-command-center',
    url: 'http://localhost:3024',
    needsLogin: true,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 5);
      await scrollToTop(page);

      // Navigate all pages
      await clickAllNavItems(page);

      // Try clicking on an incident
      try {
        const incident = page.locator('[class*="incident"], [class*="alert"], tr, [class*="card"]').first();
        await incident.click();
        await page.waitForTimeout(2000);
        await slowScroll(page, 2);
      } catch (e) {}

      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  },
  {
    name: 'llm-observability',
    url: 'http://localhost:3026',
    needsLogin: false,
    walkthrough: async (page) => {
      await page.waitForTimeout(2000);
      await slowScroll(page, 6, 500);
      await scrollToTop(page);
      await page.waitForTimeout(1000);

      // Open hamburger menu if present
      try {
        const hamburger = page.locator('[class*="hamburger"], button[aria-label*="menu"], button:has(svg[class*="menu"])').first();
        await hamburger.click();
        await page.waitForTimeout(1000);
      } catch (e) {}

      // Navigate all pages
      await clickAllNavItems(page);

      // Try interacting with filters or dropdowns
      try {
        const select = page.locator('select, [role="combobox"]').first();
        await select.click();
        await page.waitForTimeout(1000);
      } catch (e) {}

      await scrollToTop(page);
      await page.waitForTimeout(1000);
    }
  }
];

// ── Recording ────────────────────────────────────────────

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
    await page.waitForTimeout(2000);

    if (app.needsLogin) {
      console.log('   Logging in...');
      await login(page);
    }

    console.log('   Walking through all pages...');
    await app.walkthrough(page);

    // Final pause at top
    await scrollToTop(page);
    await page.waitForTimeout(2000);

  } catch (e) {
    console.log(`   ⚠️ Error: ${e.message.slice(0, 100)}`);
  }

  await page.close();
  const video = await page.video()?.path();
  await context.close();
  await browser.close();

  if (video) {
    const { rename } = await import('fs/promises');
    const webmPath = path.join(RECORDINGS_DIR, `${app.name}.webm`);
    try {
      await rename(video, webmPath);
    } catch (e) {}

    // Convert to MP4
    const mp4Path = path.join(RECORDINGS_DIR, `${app.name}.mp4`);
    const { execSync } = await import('child_process');
    try {
      execSync(`ffmpeg -y -i "${webmPath}" -c:v libx264 -preset fast -crf 22 -pix_fmt yuv420p -movflags +faststart "${mp4Path}" 2>/dev/null`);
      const { statSync } = await import('fs');
      const size = (statSync(mp4Path).size / (1024 * 1024)).toFixed(1);
      console.log(`   ✅ ${app.name}.mp4 (${size}MB)`);
    } catch (e) {
      console.log(`   ✅ ${webmPath} (mp4 conversion failed)`);
    }
  }
}

async function main() {
  console.log('🚀 Spectraal Full App Recorder — HD 1080p');
  console.log(`   Output: ${RECORDINGS_DIR}`);
  console.log(`   Apps: ${apps.length}\n`);

  for (const app of apps) {
    try {
      await recordApp(app);
    } catch (e) {
      console.log(`   ❌ Failed: ${e.message}`);
    }
  }

  console.log('\n✅ All recordings complete!');

  // List final files
  const { readdirSync, statSync } = await import('fs');
  const files = readdirSync(RECORDINGS_DIR).filter(f => f.endsWith('.mp4')).sort();
  console.log('\n📁 Final recordings:');
  for (const f of files) {
    const size = (statSync(path.join(RECORDINGS_DIR, f)).size / (1024 * 1024)).toFixed(1);
    console.log(`   ${f} — ${size}MB`);
  }
}

main().catch(console.error);
