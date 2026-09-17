defmodule TymeslotWeb.Live.Scheduling.Handlers.OneBookingPerPerson do
  @moduledoc """
  convexe fork: at most one upcoming booking per person.

  cal.convexe.org has no daily cap on purpose — a cap locks real people out on the
  day they need a slot most. What it refuses instead is one visitor holding many
  slots behind many made-up addresses. A "person" is both halves below, and
  either one refuses the booking:

    * **the attendee email** — an upcoming, not-cancelled meeting with the same
      address (read from the meetings table, so it survives restarts);
    * **the client IP** — a booking created from this address in the last 24
      hours (kept in the rate limiter's ETS table, and written only after a
      booking really exists, so a visitor who mistypes the form is not locked
      out).

  The IP half is only meaningful because the proxy in front forwards the real
  client address (see convexe-mkt `deploy/tt/agenda-ip-real.sh`).

  Rescheduling and owner previews are exempt: they do not add a booking.
  """

  import Ecto.Query

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimit

  @active ~w(pending awaiting_approval confirmed reschedule_requested awaiting_payment)
  @ip_window_seconds 24 * 60 * 60

  @doc "Whether this person may create a new booking."
  @spec allowed?(String.t() | nil, String.t() | nil) :: boolean()
  def allowed?(ip, email), do: not ip_booked?(ip) and not email_booked?(email)

  @spec ip_booked?(String.t() | nil) :: boolean()
  def ip_booked?(ip) when is_binary(ip) and ip not in ["", "unknown"] do
    RateLimit.get(ip_key(ip), @ip_window_seconds) >= 1
  end

  def ip_booked?(_ip), do: false

  @spec email_booked?(String.t() | nil) :: boolean()
  def email_booked?(email) when is_binary(email) and email != "" do
    normalised = email |> String.trim() |> String.downcase()
    now = DateTime.truncate(DateTime.utc_now(), :second)

    MeetingSchema
    |> where([m], fragment("lower(?)", m.attendee_email) == ^normalised)
    |> where([m], m.status in ^@active and m.end_time > ^now)
    |> Repo.exists?()
  end

  def email_booked?(_email), do: false

  @doc "Remembers that this IP has just booked."
  @spec record(String.t() | nil) :: :ok
  def record(ip) when is_binary(ip) and ip not in ["", "unknown"] do
    RateLimit.hit(ip_key(ip), @ip_window_seconds, 1_000)
    :ok
  end

  def record(_ip), do: :ok

  defp ip_key(ip), do: "one_booking_per_person:" <> ip
end
