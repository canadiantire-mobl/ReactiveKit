//
//  The MIT License (MIT)
//
//  Copyright (c) 2016-2019 Srdan Rasic (@srdanrasic)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

extension SignalProtocol {

    /// Transform each element by applying `transform` on it.
    public func map<U>(_ transform: @escaping (Element) -> U) -> Signal<U, Error> {
        return Signal { observer in
            return self.observe { event in
                switch event {
                case .next(let element):
                    observer.next(transform(element))
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    observer.completed()
                }
            }
        }
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMap<O: SignalProtocol>(_ strategy: FlattenStrategy, _ transform: @escaping (Element) -> O) -> Signal<O.Element, Error> where O.Error == Error {
        return map(transform).flatten(strategy)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapLatest<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, Error> where O.Error == Error {
        return flatMap(.latest, transform)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapMerge<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, Error> where O.Error == Error {
        return flatMap(.merge, transform)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapConcat<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, Error> where O.Error == Error {
        return flatMap(.concat, transform)
    }

    /// Map failure event into another operation and continue with that operation. Also called `catch`.
    public func flatMapError<S: SignalProtocol>(_ recover: @escaping (Error) -> S) -> Signal<Element, S.Error> where S.Element == Element {
        return Signal { observer in
            let serialDisposable = SerialDisposable(otherDisposable: nil)
            serialDisposable.otherDisposable = self.observe { taskEvent in
                switch taskEvent {
                case .next(let value):
                    observer.next(value)
                case .completed:
                    observer.completed()
                case .failed(let error):
                    serialDisposable.otherDisposable = recover(error).observe(with: observer.on)
                }
            }
            return serialDisposable
        }
    }
}

extension SignalProtocol where Error == Swift.Error {

    /// Transform each element by applying `transform` on it.
    public func map<U>(_ transform: @escaping (Element) throws -> U) -> Signal<U, Error> {
        return Signal { observer in
            return self.observe { event in
                switch event {
                case .next(let element):
                    do {
                        observer.next(try transform(element))
                    } catch {
                        observer.failed(error)
                    }
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    observer.completed()
                }
            }
        }
    }
}

public enum FlattenStrategy {

    /// Flatten the signal by observing and propagating emissions only from latest signal.
    /// Previous signal observation gets disposed is such exists.
    case latest

    /// Flatten the signal by sequentially observing inner signals in order in which they
    /// arrive, starting next observation only after previous one completes.
    case concat

    /// Flatten the signal by observing all inner signals and propagating events from each one as they arrive.
    case merge
}

extension SignalProtocol where Element: SignalProtocol, Element.Error == Error {

    public typealias InnerElement = Element.Element

    /// Flatten the signal with the given strategy.
    public func flatten(_ strategy: FlattenStrategy) -> Signal<InnerElement, Error> {
        switch strategy {
        case .merge:
            return merge()
        case .latest:
            return switchToLatest()
        case .concat:
            return concat()
        }
    }

    /// Flatten the signal by observing all inner signals and propagating events from each one as they arrive.
    public func merge() -> Signal<InnerElement, Error> {
        return Signal { observer in
            let lock = NSRecursiveLock(name: "reactive_kit.merge")
            let compositeDisposable = CompositeDisposable()
            var numberOfOperations = 1 // 1 for outer signal
            func decrementNumberOfOperations() {
                numberOfOperations -= 1
                if numberOfOperations == 0 {
                    observer.completed()
                }
            }
            compositeDisposable += self.observe { outerEvent in
                switch outerEvent {
                case .next(let innerSignal):
                    lock.lock()
                    numberOfOperations += 1
                    compositeDisposable += innerSignal.observe { innerEvent in
                        switch innerEvent {
                        case .next(let element):
                            observer.next(element)
                        case .failed(let error):
                            observer.failed(error)
                        case .completed:
                            decrementNumberOfOperations()
                        }
                    }
                    lock.unlock()
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    lock.lock()
                    decrementNumberOfOperations()
                    lock.unlock()
                }
            }
            return compositeDisposable
        }
    }

    /// Flatten the signal by observing and propagating emissions only from latest signal.
    public func switchToLatest() -> Signal<InnerElement, Error> {
        return Signal { observer in
            let serialDisposable = SerialDisposable(otherDisposable: nil)
            let compositeDisposable = CompositeDisposable([serialDisposable])
            var completions = (outer: false, inner: false)
            let lock = NSRecursiveLock(name: "reactive_kit.switch_to_latest")
            compositeDisposable += self.observe { outerEvent in
                switch outerEvent {
                case .next(let innerSignal):
                    lock.lock()
                    completions.inner = false
                    serialDisposable.otherDisposable?.dispose()
                    serialDisposable.otherDisposable = innerSignal.observe { innerEvent in
                        switch innerEvent {
                        case .next(let element):
                            observer.next(element)
                        case .failed(let error):
                            observer.failed(error)
                        case .completed:
                            lock.lock()
                            completions.inner = true
                            if completions.outer {
                                observer.completed()
                            }
                            lock.unlock()
                        }
                    }
                    lock.unlock()
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    lock.lock()
                    completions.outer = true
                    if completions.inner {
                        observer.completed()
                    }
                    lock.unlock()
                }
            }

            return compositeDisposable
        }
    }

    /// Flatten the signal by sequentially observing inner signals in order in which they
    /// arrive, starting next observation only after previous one completes.
    public func concat() -> Signal<InnerElement, Error> {
        return Signal { observer in
            let lock = NSRecursiveLock(name: "reactive_kit.concat")
            let serialDisposable = SerialDisposable(otherDisposable: nil)
            let compositeDisposable = CompositeDisposable([serialDisposable])
            var completions = (outer: false, inner: true)
            var innerSignalQueue: [Element] = []
            func startNextOperation() {
                completions.inner = false
                let innerSignal = innerSignalQueue.removeFirst()
                serialDisposable.otherDisposable?.dispose()
                serialDisposable.otherDisposable = innerSignal.observe { event in
                    switch event {
                    case .next(let element):
                        observer.next(element)
                    case .failed(let error):
                        observer.failed(error)
                    case .completed:
                        lock.lock()
                        completions.inner = true
                        if !innerSignalQueue.isEmpty {
                            startNextOperation()
                        } else if completions.outer {
                            observer.completed()
                        }
                        lock.unlock()
                    }
                }
            }
            func addToQueue(signal: Element) {
                lock.lock()
                innerSignalQueue.append(signal)
                if completions.inner {
                    startNextOperation()
                }
                lock.unlock()
            }
            compositeDisposable += self.observe { outerEvent in
                switch outerEvent {
                case .next(let innerSignal):
                    addToQueue(signal: innerSignal)
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    lock.lock()
                    completions.outer = true
                    if completions.inner {
                        observer.completed()
                    }
                    lock.unlock()
                }
            }
            return compositeDisposable
        }
    }
}

extension SignalProtocol where Error == Never {

    /// Map each event into a signal and then flatten inner signals.
    public func flatMap<O: SignalProtocol>(_ strategy: FlattenStrategy, _ transform: @escaping (Element) -> O) -> Signal<O.Element, O.Error> {
        return (castError() as Signal<Element, O.Error>).map(transform).flatten(strategy)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapLatest<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, O.Error> {
        return flatMap(.latest, transform)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapMerge<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, O.Error> {
        return flatMap(.merge, transform)
    }

    /// Map each event into a signal and then flatten inner signals.
    public func flatMapConcat<O: SignalProtocol>(_ transform: @escaping (Element) -> O) -> Signal<O.Element, O.Error>  {
        return flatMap(.concat, transform)
    }
}