-- ============================================================================
-- Nova Software Studio — Team Task Management Platform
-- PostgreSQL Schema
-- ============================================================================
-- Based on the provided ER Diagram:
--   Users, Projects, Tasks, Task_Assignees, Task_Dependencies, Comments, Notes
-- ============================================================================

-- Recommended: run inside a transaction
BEGIN;

-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- for gen_random_uuid() if you prefer UUID PKs

-- ----------------------------------------------------------------------------
-- ENUM Types
-- ----------------------------------------------------------------------------
CREATE TYPE user_role AS ENUM ('admin', 'member', 'viewer');

-- Pick ONE consistent set of board columns (5 statuses, per the brief).
-- Here: Backlog -> To Do -> In Progress -> In Review -> Done
CREATE TYPE task_status AS ENUM ('backlog', 'todo', 'in_progress', 'in_review', 'done');

CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high', 'urgent');

-- ----------------------------------------------------------------------------
-- Users
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(150)        NOT NULL,
    email           VARCHAR(255)        NOT NULL UNIQUE,
    password_hash   VARCHAR(255)        NOT NULL,
    role            user_role           NOT NULL DEFAULT 'member',
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_email ON users (email);

-- ----------------------------------------------------------------------------
-- Projects
-- Diagram's "creates" relation: one user creates a project (owner)
-- ----------------------------------------------------------------------------
CREATE TABLE projects (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(200)        NOT NULL,
    created_by      BIGINT              NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now()
);

CREATE INDEX idx_projects_created_by ON projects (created_by);

-- ----------------------------------------------------------------------------
-- Tasks
-- Each task belongs to exactly one project (Kanban board = project's tasks
-- grouped by status column).
-- ----------------------------------------------------------------------------
CREATE TABLE tasks (
    id                  BIGSERIAL PRIMARY KEY,
    project_id          BIGINT          NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    title               VARCHAR(255)    NOT NULL,
    description         TEXT,
    status              task_status     NOT NULL DEFAULT 'backlog',
    priority            task_priority   NOT NULL DEFAULT 'medium',
    start_date          DATE,
    due_date            DATE,
    estimated_hours     NUMERIC(6,2),
    position            INTEGER         NOT NULL DEFAULT 0,   -- ordering within a column
    subtasks            JSONB           DEFAULT '[]'::jsonb,  -- lightweight subtask checklist
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CONSTRAINT chk_task_dates CHECK (due_date IS NULL OR start_date IS NULL OR due_date >= start_date)
);

CREATE INDEX idx_tasks_project_id ON tasks (project_id);
CREATE INDEX idx_tasks_status     ON tasks (status);
CREATE INDEX idx_tasks_due_date   ON tasks (due_date);

-- ----------------------------------------------------------------------------
-- Task_Assignees (many-to-many: Users <-> Tasks)
-- ----------------------------------------------------------------------------
CREATE TABLE task_assignees (
    task_id     BIGINT      NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (task_id, user_id)
);

CREATE INDEX idx_task_assignees_user_id ON task_assignees (user_id);

-- ----------------------------------------------------------------------------
-- Task_Dependencies (self-referencing many-to-many on Tasks)
-- "depends_on_task_id" must be completed before "task_id" can proceed.
-- This is a dependency GRAPH, not a tree: a task can have many dependents
-- and many dependencies.
-- ----------------------------------------------------------------------------
CREATE TABLE task_dependencies (
    id                  BIGSERIAL PRIMARY KEY,
    task_id             BIGINT      NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    depends_on_task_id  BIGINT      NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_no_self_dependency CHECK (task_id <> depends_on_task_id),
    CONSTRAINT uq_task_dependency UNIQUE (task_id, depends_on_task_id)
);

CREATE INDEX idx_task_dependencies_task_id ON task_dependencies (task_id);
CREATE INDEX idx_task_dependencies_depends_on ON task_dependencies (depends_on_task_id);

-- ----------------------------------------------------------------------------
-- Comments (any user can comment on a task)
-- ----------------------------------------------------------------------------
CREATE TABLE comments (
    id          BIGSERIAL PRIMARY KEY,
    task_id     BIGINT      NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content     TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_comments_task_id ON comments (task_id);
CREATE INDEX idx_comments_user_id ON comments (user_id);

-- ----------------------------------------------------------------------------
-- Notes (personal notes owned by a user — from "owns_notes" relation)
-- ----------------------------------------------------------------------------
CREATE TABLE notes (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content     TEXT        NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notes_user_id ON notes (user_id);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Auto-update notes.updated_at on modification
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER notes_set_updated_at
    BEFORE UPDATE ON notes
    FOR EACH ROW
    EXECUTE FUNCTION trg_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2) Cycle detection on task_dependencies
--    Prevents circular dependencies (A -> B -> C -> A) at INSERT time.
--    Uses a recursive CTE to walk from the new dependency's target
--    (depends_on_task_id) forward through the graph; if we ever reach
--    task_id again, a cycle would be created and the insert is rejected.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION prevent_dependency_cycle()
RETURNS TRIGGER AS $$
DECLARE
    cycle_found BOOLEAN;
BEGIN
    WITH RECURSIVE dependency_chain AS (
        -- Start from what the new row says the task depends on
        SELECT depends_on_task_id AS current_task
        FROM task_dependencies
        WHERE task_id = NEW.depends_on_task_id

        UNION ALL

        SELECT td.depends_on_task_id
        FROM task_dependencies td
        JOIN dependency_chain dc ON td.task_id = dc.current_task
    )
    SELECT EXISTS (
        SELECT 1 FROM dependency_chain WHERE current_task = NEW.task_id
        UNION
        SELECT 1 WHERE NEW.depends_on_task_id = NEW.task_id
    ) INTO cycle_found;

    IF cycle_found THEN
        RAISE EXCEPTION
            'Circular dependency detected: task % cannot depend on task % (would create a cycle)',
            NEW.task_id, NEW.depends_on_task_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER task_dependencies_prevent_cycle
    BEFORE INSERT OR UPDATE ON task_dependencies
    FOR EACH ROW
    EXECUTE FUNCTION prevent_dependency_cycle();

-- ----------------------------------------------------------------------------
-- 3) Enforce dependency order on the board (optional but recommended):
--    A task cannot move OUT of 'todo'/'backlog' into 'in_progress' or beyond
--    while any of its dependencies are not yet 'done'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_dependency_order()
RETURNS TRIGGER AS $$
DECLARE
    unmet_count INTEGER;
BEGIN
    IF NEW.status IN ('in_progress', 'in_review', 'done')
       AND (OLD.status IS DISTINCT FROM NEW.status) THEN

        SELECT COUNT(*) INTO unmet_count
        FROM task_dependencies td
        JOIN tasks dep ON dep.id = td.depends_on_task_id
        WHERE td.task_id = NEW.id
          AND dep.status <> 'done';

        IF unmet_count > 0 THEN
            RAISE EXCEPTION
                'Task % has % unfinished dependency task(s); cannot move to status %',
                NEW.id, unmet_count, NEW.status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tasks_enforce_dependency_order
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION enforce_dependency_order();

COMMIT;

-- ============================================================================
-- Sample helper query: topological-friendly view for the AI scheduler
-- (list of tasks with their unmet dependency count — feed this into the
-- topological sort step before calling the AI for ordering suggestions)
-- ============================================================================
-- CREATE VIEW task_dependency_summary AS
-- SELECT
--     t.id,
--     t.title,
--     t.priority,
--     t.due_date,
--     t.estimated_hours,
--     t.status,
--     COALESCE(array_agg(td.depends_on_task_id) FILTER (WHERE td.depends_on_task_id IS NOT NULL), '{}') AS depends_on
-- FROM tasks t
-- LEFT JOIN task_dependencies td ON td.task_id = t.id
-- GROUP BY t.id;
-- يوزر تجريبي (الباسورد هنا مجرد نص عادي للتجربة، مش هاش حقيقي)
INSERT INTO users (name, email, password_hash, role)
VALUES ('Sara Ahmed', 'sara@nova.com', 'test_hash_123', 'admin')
RETURNING id;

INSERT INTO users (name, email, password_hash, role)
VALUES ('Omar Khaled', 'omar@nova.com', 'test_hash_456', 'member')
RETURNING id;

-- مشروع تجريبي (هنفترض إن يوزر sara هو اللي عمله، وهيكون id = 1)
INSERT INTO projects (name, created_by)
VALUES ('Client Website Redesign', 1)
RETURNING id;

-- تاسكين تجريبيين على نفس المشروع (project_id = 1)
INSERT INTO tasks (project_id, title, description, status, priority, due_date)
VALUES (1, 'Design homepage mockup', 'Create the initial Figma design', 'todo', 'high', '2026-10-01')
RETURNING id;

INSERT INTO tasks (project_id, title, description, status, priority, due_date)
VALUES (1, 'Setup hosting', 'Configure the production server', 'backlog', 'medium', '2026-10-10')
RETURNING id;

-- تعيين omar على التاسك الأول (task_id = 1, user_id = 2)
INSERT INTO task_assignees (task_id, user_id) VALUES (1, 2);

-- تعليق على التاسك
INSERT INTO comments (task_id, user_id, content)
VALUES (1, 2, 'Started working on the wireframes today');

-- التاسك التاني معتمد على الأول (يعني لازم الأول يخلص الأول)
INSERT INTO task_dependencies (task_id, depends_on_task_id) VALUES (2, 1);

-- بيمسح كل حاجة (جداول، types، triggers) عشان تقدري تبدأي نضيف
DROP TABLE IF EXISTS comments CASCADE;
DROP TABLE IF EXISTS notes CASCADE;
DROP TABLE IF EXISTS task_dependencies CASCADE;
DROP TABLE IF EXISTS task_assignees CASCADE;
DROP TABLE IF EXISTS tasks CASCADE;
DROP TABLE IF EXISTS projects CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP TYPE IF EXISTS task_priority;
DROP TYPE IF EXISTS task_status;
DROP TYPE IF EXISTS user_role;
ROLLBACK;
select * from users;