"""Offline evaluator for the synthetic cook-off. NEVER ingest this as memory.

Checks targeted extraction regressions, not full scenario reasoning or tenancy.
Accepts the native get_episode_entities response body (nodes/edges).
"""
import json


def evaluate(graph):
    nodes = graph["nodes"]
    names = {n["name"]: n for n in nodes}
    checks = {}

    def node(name):
        return names.get(name, {})

    def attrs(name):
        return node(name).get("attributes", {})

    def text(value):
        return json.dumps(value).lower()

    flight = "Monday Houston to SFO flight option"
    review = "Northstar investment committee review Monday 2pm"
    ret = "Friday Houston return flight option"
    school = "Charlie's school performance Friday 6:30pm"
    dinner = "Robin's Friday tasting-menu dinner option"
    dive = "Pacific shark-diving excursion option"
    task = "Move Friday return flight later — cross-channel task"
    cache = "Casey's cached calendar coverage and freshness"
    trip = "Pacific trip planning October 5–9"
    checks["meeting_time_and_reschedule_count"] = (
        attrs(review).get("start_at") == "2026-10-05T14:00:00-05:00"
        and attrs(review).get("end_at") == "2026-10-05T15:00:00-05:00"
        and attrs(review).get("reschedule_count") == 2)
    checks["flight_offsets"] = (attrs(flight).get("departure_at") == "2026-10-05T11:00:00-05:00"
                                  and attrs(flight).get("arrival_at") == "2026-10-05T13:00:00-07:00")
    checks["return_buffers"] = all(v in text(attrs(ret).get("logistics")) for v in ("30", "60"))
    checks["return_and_school_timing"] = (attrs(ret).get("arrival_at") == "2026-10-09T18:00:00-05:00"
                                          and attrs(school).get("arrival_target") == "2026-10-09T18:15:00-05:00")
    checks["menu_and_unconfirmed_substitution"] = all(v in text(attrs(dinner).get("constraints"))
                                                         for v in ("steak", "chicken", "shrimp", "not confirmed"))
    checks["dive_hold"] = attrs(dive).get("hold_expires_at") == "2026-10-06T12:00:00-07:00"
    checks["dive_price_and_basis"] = (attrs(dive).get("price_amount") == 350
                                        and attrs(dive).get("price_currency") == "USD"
                                        and attrs(dive).get("price_basis") == "per person")
    checks["task_distinct_from_transaction"] = (
        "TaskReference" in node(task).get("labels", [])
        and "TransactionReference" in node(ret).get("labels", [])
        and node(task).get("uuid") != node(ret).get("uuid"))
    checks["task_and_thread_ids"] = (attrs(task).get("external_id") == "sim:te:flight-001"
                                       and attrs(task).get("thread_id") == "sim:thread:flight-001")
    checks["draft_indicator_and_pending_task"] = (
        "draft" in text(attrs(task).get("communication_state"))
        and attrs(task).get("reported_status") == "awaiting_owner_decision")
    checks["calendar_refresh_and_coverage"] = (
        attrs(cache).get("last_synced_at") == "2026-10-03T08:00:00-05:00"
        and attrs(cache).get("coverage") == ["work"]
        and all(v in text(attrs(cache).get("limitations")) for v in ("personal", "school", "not a live")))
    checks["vendor_current_time"] = attrs("Vendor call moved from Monday to Tuesday").get("start_at") == "2026-10-06T16:00:00-05:00"
    checks["budget_components"] = (attrs(trip).get("budget_amount") == 2000
                                     and all(v in text(attrs(trip).get("cost_estimates")) for v in ("800", "700", "200")))
    checks["distinct_alex_identities"] = (bool(node("Alex Chen")) and bool(node("Alex Rivera"))
                                           and node("Alex Chen")["uuid"] != node("Alex Rivera")["uuid"])
    checks["morgan_write_test_unseeded"] = (bool(node("Morgan Vale"))
        and not any(v in text([node("Morgan Vale").get("summary"), attrs("Morgan Vale")]) for v in ("vegan", "hiking")))
    checks["hotel_interaction_reference"] = (
        attrs("Conversation about a quiet beach hotel").get("external_id") == "sim:interaction:hotel-002"
        and attrs("Conversation about a quiet beach hotel").get("thread_id") == "sim:thread:hotel-002")
    return checks
