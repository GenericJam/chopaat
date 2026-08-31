ExUnit.start()

# The scripted-shells holder for session-draw injection lives for the whole
# run (a test-linked process would die between tests).
{:ok, _pid} = Chopaat.Support.ScriptedDice.start()
