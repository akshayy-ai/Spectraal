import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { statSync } from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RECORDINGS_DIR = path.join(__dirname, 'recordings');

async function main() {
  console.log('🎮 Recording Tic Tac Toe Arena — Full Walkthrough');

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
  await page.goto('http://localhost:3015', { waitUntil: 'networkidle', timeout: 15000 });
  await page.waitForTimeout(2000);

  await page.locator('input[type="email"]').first().fill('admin@demo.com');
  await page.waitForTimeout(400);
  await page.locator('input[type="password"]').first().fill('demo123');
  await page.waitForTimeout(400);
  await page.locator('button[type="submit"]').first().click();
  await page.waitForTimeout(3000);

  // ── Dashboard ──────────────────────────────────
  console.log('   Dashboard overview...');
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(1000);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(1000);
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(1000);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1500);

  // ── Open sidebar ───────────────────────────────
  console.log('   Opening sidebar...');
  // Click hamburger menu (top-left)
  try {
    const hamburger = page.locator('button').first();
    await hamburger.click();
    await page.waitForTimeout(1500);
  } catch(e) {}

  // ── Navigate to New Game ───────────────────────
  console.log('   Starting new game...');
  try {
    await page.locator('a[href="/play"]').first().click();
    await page.waitForTimeout(2000);
  } catch(e) {
    // Try clicking text
    await page.locator('text=New Game').first().click();
    await page.waitForTimeout(2000);
  }

  // ── Select PvP mode ────────────────────────────
  console.log('   Selecting Player vs Player...');
  await page.locator('text=Player vs Player').first().click();
  await page.waitForTimeout(1000);

  // Fill player 2 name
  await page.mouse.wheel(0, 200);
  await page.waitForTimeout(500);
  const nameInput = page.locator('input[type="text"]').first();
  await nameInput.fill('Claude');
  await page.waitForTimeout(800);

  // Scroll to Start Game
  await page.mouse.wheel(0, 300);
  await page.waitForTimeout(500);

  // Click Start Game
  await page.locator('button:has-text("Start Game")').first().click();
  await page.waitForTimeout(2000);

  // Scroll to see the full board
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(1000);

  // ── Play the game! ─────────────────────────────
  console.log('   Playing the game...');

  // Get all cell buttons on the game board
  // The board has 9 buttons that are the cells
  // We need to find them — they're empty buttons in a grid

  // Strategy: find all buttons that are NOT Restart/Forfeit/hamburger
  const getAllCells = async () => {
    return page.locator('button:not(:has-text("Restart")):not(:has-text("Forfeit")):not(:has-text("menu")):not([aria-label])');
  };

  // Game moves — alternating X and O (PvP mode)
  // Try to make an interesting game pattern
  // Top-left, center, top-right, mid-left, bottom-left (X wins diagonal... maybe)

  // Move 1: X plays center
  let cells = await getAllCells();
  let count = await cells.count();
  console.log(`   Found ${count} clickable elements`);

  // Let's use coordinate-based clicking on the board area
  // Board is roughly centered, 3x3 grid
  // At 1920x1080 viewport, board cells are approximately:
  const boardMoves = [
    { x: 960, y: 400, label: 'Center' },        // Move 1: X center
    { x: 700, y: 250, label: 'Top-left' },       // Move 2: O top-left
    { x: 960, y: 250, label: 'Top-center' },     // Move 3: X top-center
    { x: 1220, y: 400, label: 'Mid-right' },     // Move 4: O mid-right
    { x: 960, y: 550, label: 'Bottom-center' },  // Move 5: X bottom-center → X wins!
  ];

  for (const move of boardMoves) {
    console.log(`   Move: ${move.label}`);
    await page.mouse.click(move.x, move.y);
    await page.waitForTimeout(1500);
  }

  // If game didn't end, try more moves
  const moreMoves = [
    { x: 700, y: 400, label: 'Mid-left' },
    { x: 1220, y: 250, label: 'Top-right' },
    { x: 700, y: 550, label: 'Bottom-left' },
    { x: 1220, y: 550, label: 'Bottom-right' },
  ];

  for (const move of moreMoves) {
    try {
      console.log(`   Move: ${move.label}`);
      await page.mouse.click(move.x, move.y);
      await page.waitForTimeout(1200);
    } catch(e) {}
  }

  // Pause to show result
  await page.waitForTimeout(3000);

  // ── Play Again ─────────────────────────────────
  console.log('   Checking for Play Again...');
  try {
    const playAgain = page.locator('button:has-text("Play Again"), button:has-text("New Game"), button:has-text("Rematch")').first();
    await playAgain.click({ timeout: 3000 });
    await page.waitForTimeout(2000);

    // Quick second game
    console.log('   Playing second game...');
    for (const move of boardMoves.slice(0, 4)) {
      await page.mouse.click(move.x, move.y);
      await page.waitForTimeout(1000);
    }
    await page.waitForTimeout(2000);
  } catch(e) {
    console.log('   No play again button found');
  }

  // ── Check History ──────────────────────────────
  console.log('   Checking history...');
  try {
    // Open sidebar
    const hamburger = page.locator('button').first();
    await hamburger.click();
    await page.waitForTimeout(1000);

    await page.locator('a[href*="history"], text=History').first().click();
    await page.waitForTimeout(2000);
    await page.mouse.wheel(0, 300);
    await page.waitForTimeout(1000);
  } catch(e) {
    console.log('   Could not navigate to history');
  }

  // ── Back to dashboard ──────────────────────────
  try {
    const hamburger = page.locator('button').first();
    await hamburger.click();
    await page.waitForTimeout(1000);
    await page.locator('a[href="/"], a[href="/dashboard"], text=Dashboard').first().click();
    await page.waitForTimeout(2000);
  } catch(e) {}

  // Final pause
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }));
  await page.waitForTimeout(2000);

  // ── Save ───────────────────────────────────────
  await page.close();
  const video = await page.video()?.path();
  await context.close();
  await browser.close();

  if (video) {
    const { rename } = await import('fs/promises');
    const webmPath = path.join(RECORDINGS_DIR, 'tic-tac-toe.webm');
    await rename(video, webmPath);

    const mp4Path = path.join(RECORDINGS_DIR, 'tic-tac-toe.mp4');
    execSync(`ffmpeg -y -i "${webmPath}" -c:v libx264 -preset fast -crf 22 -pix_fmt yuv420p -movflags +faststart "${mp4Path}" 2>/dev/null`);
    const size = (statSync(mp4Path).size / (1024 * 1024)).toFixed(1);
    console.log(`\n   ✅ tic-tac-toe.mp4 (${size}MB)`);
  }
}

main().catch(console.error);
