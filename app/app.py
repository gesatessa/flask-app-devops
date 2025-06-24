import os
from datetime import datetime, timedelta
from random import randint

from flask import request, jsonify
from sqlalchemy import text
from apscheduler.schedulers.background import BackgroundScheduler

from config import app, db


port_number = int(os.environ.get("APP_PORT", 5000))
next_checkin_time = datetime.utcnow()


@app.route("/health_check")
def health_check():
    return "OK!!!"


@app.route("/readiness_check")
def readiness_check():
    try:
        db.session.execute(text("SELECT 1"))
        return "OK!!!"
    except Exception as e:
        app.logger.error(e)
        return "failed", 500


@app.route("/checkin", methods=["POST"])
def checkin():
    global next_checkin_time

    data = request.get_json()
    user_id = data.get("user_id")
    cooldown = int(data.get("cooldown_minutes", randint(1, 5)))

    if not user_id:
        return jsonify({"error": "user_id is required"}), 400

    if cooldown < 1 or cooldown > 5:
        return jsonify({"error": "cooldown_minutes must be between 1 and 5"}), 400

    now = datetime.utcnow()
    if now < next_checkin_time:
        wait_sec = int((next_checkin_time - now).total_seconds())
        return jsonify({"error": f"Too early. Try again in {wait_sec} seconds."}), 429

    try:
        db.session.execute(
            text("""
                INSERT INTO checkins (user_id, created_at, cooldown_minutes)
                VALUES (:user_id, :created_at, :cooldown_minutes)
            """),
            {"user_id": user_id, "created_at": now, "cooldown_minutes": cooldown}
        )
        db.session.commit()
        next_checkin_time = now + timedelta(minutes=cooldown)
        return jsonify({"message": f"User {user_id} checked in successfully for {cooldown} mins."})
    except Exception as e:
        app.logger.error(e)
        return jsonify({"error": "Failed to check in user."}), 500


@app.route("/api/reports/daily_checkins", methods=["GET"])
def daily_checkins():
    result = db.session.execute(text("""
        SELECT DATE(created_at) AS date, COUNT(*) AS checkins
        FROM checkins
        GROUP BY DATE(created_at)
        ORDER BY date DESC
    """))
    return jsonify({str(row[0]): row[1] for row in result})


@app.route("/api/reports/user_activity", methods=["GET"])
def user_activity():
    result = db.session.execute(text("""
        SELECT users.id, users.first_name, users.last_name, COUNT(checkins.id) AS checkin_count
        FROM users
        LEFT JOIN checkins ON users.id = checkins.user_id
        GROUP BY users.id
        ORDER BY checkin_count DESC
    """))
    return jsonify([
        {"user_id": row[0], "name": f"{row[1]} {row[2]}", "checkins": row[3]}
        for row in result
    ])


def simulate_checkin():
    global next_checkin_time

    with app.app_context():
        now = datetime.utcnow()
        if now < next_checkin_time:
            app.logger.info("⏳ Cooldown active. Skipping simulated check-in.")
            return

        user_ids = [row[0] for row in db.session.execute(text("SELECT id FROM users")).fetchall()]
        if not user_ids:
            return

        random_user_id = user_ids[randint(0, len(user_ids) - 1)]
        cooldown = randint(1, 5)

        db.session.execute(
            text("""
                INSERT INTO checkins (user_id, created_at, cooldown_minutes)
                VALUES (:user_id, :created_at, :cooldown_minutes)
            """),
            {"user_id": random_user_id, "created_at": now, "cooldown_minutes": cooldown}
        )
        db.session.commit()
        next_checkin_time = now + timedelta(minutes=cooldown)
        app.logger.info(f"🤖 Simulated check-in for user {random_user_id} with cooldown {cooldown}m")


scheduler = BackgroundScheduler()
# Runs every 30s but may skip if cooldown
scheduler.add_job(simulate_checkin, 'interval', seconds=30)
scheduler.start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=port_number)
