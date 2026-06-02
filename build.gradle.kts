plugins {
  id("com.diffplug.spotless") version "6.25.0"
}

spotless {
  sql {
    target("migrations/sql/**/*.sql")
    dbeaver()
    indentWithTabs(2)
    endWithNewline()
  }
}
