<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.2.6

This release adds island terrains with an automatic rotation, image and file previews in prompt bubbles, and more reliable jumping to the app hosting a session.

## Island

- Adds water and ground terrains alongside grassland, selectable under Appearance
- Adds an Auto option that cycles through the terrains every 30 minutes, starting from a random one
- Fades the ground and its craters uniformly when the panel dims

## Panel

- Shows attached images as previews in prompt bubbles
- Renders file mentions as chips in prompt bubbles and the activity feed, keeping links inside them clickable
- Hides the usage ring until it has data and compacts the idle notch

## Sessions

- Jumps to the correct host app for sessions running inside T3 Code, falling back to the Codex thread URL when activation fails
- Remembers the hosting app so stale sessions no longer launch Codex
- Ends Codex sessions hosted by a known app when their process exits
- Tapping a lone grass mascot jumps to its host app

## Usage

- Keeps today's slot visible in the usage chart
- Enlarges the provider breakdown text in the cost dashboard

## Settings

- Clarifies the notch slot labels
