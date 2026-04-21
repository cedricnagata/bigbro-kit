// BigBroKit — iOS framework for connecting to BigBro Mac hosts.
//
// Public API entry point: BigBroClient
//
//   let client = BigBroClient()
//   let devices = await client.discover()
//   try await client.pair(with: devices[0])
//   let reply = try await client.chat([.user("Hello")])
