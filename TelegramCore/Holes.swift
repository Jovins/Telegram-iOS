import Foundation
import SwiftSignalKit
import Postbox
import MtProtoKit

private func messageFilterForTagMask(_ tagMask: MessageTags) -> Api.MessagesFilter? {
    if tagMask == .PhotoOrVideo {
        return Api.MessagesFilter.inputMessagesFilterPhotoVideo
    } else {
        return nil
    }
}

func fetchMessageHistoryHole(network: Network, postbox: Postbox, hole: MessageHistoryHole, direction: HoleFillDirection, tagMask: MessageTags?) -> Signal<Void, NoError> {
    return postbox.peerWithId(hole.maxIndex.id.peerId)
        |> take(1)
        //|> delay(4.0, queue: Queue.concurrentDefaultQueue())
        |> mapToSignal { peer in
            if let inputPeer = apiInputPeer(peer) {
                let limit = 100
                
                let request: Signal<Api.messages.Messages, MTRpcError>
                if let tagMask = tagMask, let filter = messageFilterForTagMask(tagMask) {
                    switch direction {
                        case .UpperToLower:
                            break
                        case .LowerToUpper:
                            assertionFailure(".LowerToUpper not supported")
                        case .AroundIndex:
                            assertionFailure(".AroundIndex not supported")
                    }
                    request = network.request(Api.functions.messages.search(flags: 0, peer: inputPeer, q: "", filter: filter, minDate: 0, maxDate: hole.maxIndex.timestamp, offset: 0, maxId: hole.maxIndex.id.id + 1, limit: Int32(limit)))
                } else {
                    let offsetId: Int32
                    let addOffset: Int32
                    let selectedLimit = limit
                    switch direction {
                        case .UpperToLower:
                            offsetId = hole.maxIndex.id.id == Int32.max ? hole.maxIndex.id.id : (hole.maxIndex.id.id + 1)
                            addOffset = 0
                        case .LowerToUpper:
                            offsetId = hole.min <= 1 ? 1 : (hole.min - 1)
                            addOffset = Int32(-limit)
                        case let .AroundIndex(index):
                            offsetId = index.id.id
                            addOffset = Int32(-limit / 2)
                    }
                    
                    request = network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: offsetId, offsetDate: hole.maxIndex.timestamp, addOffset: addOffset, limit: Int32(selectedLimit), maxId: hole.maxIndex.id.id == Int32.max ? hole.maxIndex.id.id : (hole.maxIndex.id.id + 1), minId: hole.min - 1))
                }
                
                return request
                    |> retryRequest
                    |> mapToSignal { result in
                        let messages: [Api.Message]
                        let chats: [Api.Chat]
                        let users: [Api.User]
                        switch result {
                            case let .messages(messages: apiMessages, chats: apiChats, users: apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let .messagesSlice(_, messages: apiMessages, chats: apiChats, users: apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let .channelMessages(_, _, _, apiMessages, apiChats, apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                        }
                        return postbox.modify { modifier in
                            var storeMessages: [StoreMessage] = []
                            
                            for message in messages {
                                if let storeMessage = StoreMessage(apiMessage: message) {
                                    if case let .Id(storeId) = storeMessage.id, storeId.id >= hole.min && storeId.id <= hole.maxIndex.id.id {
                                        storeMessages.append(storeMessage)
                                    }
                                }
                            }
                            
                            modifier.fillHole(hole, fillType: HoleFill(complete: messages.count == 0, direction: direction), tagMask: tagMask, messages: storeMessages)
                            
                            var peers: [Peer] = []
                            for chat in chats {
                                let telegramGroup = TelegramGroup(chat: chat)
                                peers.append(telegramGroup)
                            }
                            for user in users {
                                let telegramUser = TelegramUser(user: user)
                                peers.append(telegramUser)
                            }
                            
                            modifier.updatePeers(peers, update: { _, updated -> Peer in
                                return updated
                            })
                            
                            return
                        }
                    }
            } else {
                return fail(Void.self, NoError())
            }
        }
}

func fetchChatListHole(network: Network, postbox: Postbox, hole: ChatListHole) -> Signal<Void, NoError> {
    let offset: Signal<(Int32, Int32, Api.InputPeer), NoError>
    if hole.index.id.peerId.namespace == Namespaces.Peer.Empty {
        offset = single((0, 0, Api.InputPeer.inputPeerEmpty), NoError.self)
    } else {
        offset = postbox.peerWithId(hole.index.id.peerId)
            |> take(1)
            |> map { peer in
                return (hole.index.timestamp, hole.index.id.id + 1, apiInputPeer(peer) ?? .inputPeerEmpty)
            }
    }
    return offset
        |> mapToSignal { (timestamp, id, peer) in
        return network.request(Api.functions.messages.getDialogs(offsetDate: timestamp, offsetId: id, offsetPeer: peer, limit: 100))
            |> retryRequest
            |> mapToSignal { result -> Signal<Void, NoError> in
                let dialogsChats: [Api.Chat]
                let dialogsUsers: [Api.User]
                
                var replacementHole: ChatListHole?
                var storeMessages: [StoreMessage] = []
                var readStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
                var chatStates: [PeerId: PeerChatState] = [:]
                
                switch result {
                    case let .dialogs(dialogs, messages, chats, users):
                        dialogsChats = chats
                        dialogsUsers = users
                        
                        for dialog in dialogs {
                            let apiPeer: Api.Peer
                            let apiReadInboxMaxId: Int32
                            let apiReadOutboxMaxId: Int32
                            let apiTopMessage: Int32
                            let apiUnreadCount: Int32
                            var apiChannelPts: Int32?
                            switch dialog {
                                case let .dialog(_, peer, topMessage, readInboxMaxId, readOutboxMaxId, unreadCount, _, pts, _):
                                    apiPeer = peer
                                    apiTopMessage = topMessage
                                    apiReadInboxMaxId = readInboxMaxId
                                    apiReadOutboxMaxId = readOutboxMaxId
                                    apiUnreadCount = unreadCount
                                    apiChannelPts = pts
                            }
                            
                            let peerId: PeerId
                            switch apiPeer {
                                case let .peerUser(userId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                                case let .peerChat(chatId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                                case let .peerChannel(channelId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                            }
                            
                            if readStates[peerId] == nil {
                                readStates[peerId] = [:]
                            }
                            readStates[peerId]![Namespaces.Message.Cloud] = PeerReadState(maxIncomingReadId: apiReadInboxMaxId, maxOutgoingReadId: apiReadOutboxMaxId, maxKnownId: apiTopMessage, count: apiUnreadCount)
                            
                            if let apiChannelPts = apiChannelPts {
                                chatStates[peerId] = ChannelState(pts: apiChannelPts)
                            }
                        }
                        
                        for message in messages {
                            if let storeMessage = StoreMessage(apiMessage: message) {
                                storeMessages.append(storeMessage)
                            }
                        }
                    case let .dialogsSlice(_, dialogs, messages, chats, users):
                        for message in messages {
                            if let storeMessage = StoreMessage(apiMessage: message) {
                                storeMessages.append(storeMessage)
                            }
                        }
                        
                        dialogsChats = chats
                        dialogsUsers = users
                        
                        for dialog in dialogs {
                            let apiPeer: Api.Peer
                            let apiTopMessage: Int32
                            let apiReadInboxMaxId: Int32
                            let apiReadOutboxMaxId: Int32
                            let apiUnreadCount: Int32
                            switch dialog {
                                case let .dialog(_, peer, topMessage, readInboxMaxId, readOutboxMaxId, unreadCount, _, _, _):
                                    apiPeer = peer
                                    apiTopMessage = topMessage
                                    apiReadInboxMaxId = readInboxMaxId
                                    apiReadOutboxMaxId = readOutboxMaxId
                                    apiUnreadCount = unreadCount
                            }
                            
                            let peerId: PeerId
                            switch apiPeer {
                                case let .peerUser(userId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                                case let .peerChat(chatId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                                case let .peerChannel(channelId):
                                    peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                            }
                            
                            if readStates[peerId] == nil {
                                readStates[peerId] = [:]
                            }
                            readStates[peerId]![Namespaces.Message.Cloud] = PeerReadState(maxIncomingReadId: apiReadInboxMaxId, maxOutgoingReadId: apiReadOutboxMaxId, maxKnownId: apiTopMessage, count: apiUnreadCount)
                            
                            let topMessageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: apiTopMessage)
                            
                            var timestamp: Int32?
                            for message in storeMessages {
                                if case let .Id(id) = message.id, id == topMessageId {
                                    timestamp = message.timestamp
                                }
                            }
                            
                            if let timestamp = timestamp {
                                let index = MessageIndex(id: MessageId(peerId: topMessageId.peerId, namespace: topMessageId.namespace, id: topMessageId.id - 1), timestamp: timestamp)
                                if replacementHole == nil || replacementHole!.index > index {
                                    replacementHole = ChatListHole(index: index)
                                }
                            }
                        }
                }
                
                var peers: [Peer] = []
                for chat in dialogsChats {
                    let telegramGroup = TelegramGroup(chat: chat)
                    peers.append(telegramGroup)
                }
                for user in dialogsUsers {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                }
                
                return postbox.modify { modifier in
                    modifier.updatePeers(peers, update: { _, updated -> Peer in
                        return updated
                    })
                    
                    var allPeersWithMessages = Set<PeerId>()
                    for message in storeMessages {
                        if !allPeersWithMessages.contains(message.id.peerId) {
                            allPeersWithMessages.insert(message.id.peerId)
                        }
                    }
                    modifier.addMessages(storeMessages, location: .UpperHistoryBlock)
                    modifier.replaceChatListHole(hole.index, hole: replacementHole)
                    
                    modifier.resetIncomingReadStates(readStates)
                    
                    for (peerId, chatState) in chatStates {
                        modifier.setPeerChatState(peerId, state: chatState)
                    }
                }
            }
        }
}
