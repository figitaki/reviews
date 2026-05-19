# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

Reviews.DemoReview.seed!()
IO.puts("Seeded demo review at /r/#{Reviews.DemoReview.slug()}")
