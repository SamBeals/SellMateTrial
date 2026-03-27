# AGENTS.md

## Project
SellMateTrial

This appears to be an earlier or experimental iOS repo for SellMate, centered on Stripe reader connection, planogram editing/viewing, and early vending workflows.

## Observed Role
This repo looks useful as:
- a prototype
- a reference implementation
- a sandbox for reader or UI experimentation

It should not automatically be treated as the production source of truth if similar code exists in `SellMateCustomer`.

## Guidance
When editing this repo:
- first determine whether the change belongs here or in `SellMateCustomer`
- preserve its usefulness as a prototype/reference unless told to repurpose it
- clearly document whether code is experimental, legacy, or intended for migration

## Coding Preferences
- keep changes focused
- avoid large production-hardening efforts unless explicitly requested
- prefer comments that explain what was learned or what should be migrated elsewhere

## Validation
Before finishing:
- confirm whether the feature is prototype-only or intended to move upstream
- note overlap with `SellMateCustomer`
- avoid duplicating work across both repos without a reason
