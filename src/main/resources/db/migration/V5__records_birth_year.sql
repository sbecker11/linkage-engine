-- Add optional birth_year column to records table.
-- Used by AgeConsistencyRule and BiologicalPlausibilityRule for age-based
-- identity resolution across records of the same individual.
ALTER TABLE records ADD COLUMN IF NOT EXISTS birth_year INTEGER;
