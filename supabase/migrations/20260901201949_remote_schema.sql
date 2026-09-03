SET local check_function_bodies = off;

CREATE TABLE "public"."task_events" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "task_id"         uuid                     NOT NULL,
  "event_type"      text                     NOT NULL,
  "actor"           text,
  "call_id"         text,
  "parent_event_id" uuid,
  "outcome"         text,
  "extracted_data"  jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "task_events_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."task_events"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."tasks" (
  "id"                   uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "task_type"            text                     NOT NULL,
  "goal"                 text                     NOT NULL,
  "status"               text                     NOT NULL DEFAULT 'new'::text,
  "current_step"         text,
  "next_action"          text,
  "waiting_for"          text,
  "pending_question"     text,
  "resume_condition"     text,
  "context"              jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "priority"             integer                  NOT NULL DEFAULT 3,
  "retry_count"          integer                  NOT NULL DEFAULT 0,
  "next_action_at"       timestamp with time zone,
  "last_contact_attempt" timestamp with time zone,
  "created_at"           timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"           timestamp with time zone NOT NULL DEFAULT now(),
  "completed_at"         timestamp with time zone,
  CONSTRAINT "tasks_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."tasks"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.update_updated_at()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

ALTER TABLE "public"."task_events"
  ADD CONSTRAINT "task_events_parent_event_id_fkey" FOREIGN KEY (parent_event_id) REFERENCES public.task_events(id);

ALTER TABLE "public"."task_events"
  ADD CONSTRAINT "task_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;

CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

GRANT EXECUTE ON FUNCTION "public"."update_updated_at"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."task_events" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."tasks" TO "anon", "authenticated", "postgres", "service_role";

