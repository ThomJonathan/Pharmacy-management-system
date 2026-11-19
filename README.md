# Stocka

A pharmacy management system: inventory management and a point of sale, in one app.

Stocka is built with Flutter and Supabase and runs on Windows, Android and the web.

## Overview

Stocka helps a pharmacy business run its day-to-day operations across one or more branches. An admin sets up branches and staff, records purchases, and reviews reports. Cashiers ring up sales, print receipts and, when the admin allows it, update stock.

The interface adapts to screen size: a bottom navigation bar on mobile and a side navigation rail on desktop.

## Live Demo

Try the web version here: **https://stocka-two.vercel.app**

The demo runs on sample data, so feel free to explore. Please do not enter real patient or business information.

## Key Features

### Admin

- **Branches:** Add shops to the system and delete them when no longer needed.
- **Users:** Create users, assign them to a branch with a role, remove them from a branch, or delete them completely.
- **Inventory:** Track medicine stock and availability per branch.
- **Purchases:** Create purchases for a specific branch.
- **Reports:** Sales, expenses and best sellers over a chosen period: today, this week, this month, this year, a specific date, a custom range, or the last N years.
- **Stock access control:** Approve or deny cashier requests to edit stock, and remove the privilege once the stock entry is finished.

### Cashier

- **Point of sale:** Record sales at the counter.
- **Printable receipts:** Print a receipt after every sale.
- **Stock:** Available once the admin approves a stock access request.
- **Reports:** Sales reports for their own branch.

## Tech Stack

- **Frontend:** Flutter, Dart
- **Backend and database:** Supabase (PostgreSQL, Auth, Row Level Security)
- **Web hosting:** Vercel (Flutter Web)
- **CI and distribution:** GitHub Actions, with an Inno Setup installer for Windows and a signed build for Android

## Author

Jonathan Thom. [GitHub](https://github.com/ThomJonathan)
