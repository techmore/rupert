package com.rupertpos.rupert

/** The app, without fetching navigation rules from the real server. */
class TestApplication : RupertApplication() {
    override val loadsRemotePathConfiguration = false
}
