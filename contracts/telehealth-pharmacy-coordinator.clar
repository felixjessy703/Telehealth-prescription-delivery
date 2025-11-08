;; title: telehealth-pharmacy-coordinator
;; version: 1.0.0
;; summary: Smart contract for coordinating telehealth consultations with pharmacy fulfillment and delivery
;; description: Manages virtual consultations, prescriptions, pharmacy orders, deliveries, and patient adherence tracking

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-status (err u104))
(define-constant err-invalid-value (err u105))
(define-constant err-not-patient (err u106))
(define-constant err-not-provider (err u107))
(define-constant err-prescription-expired (err u108))

;; Data Variables
(define-data-var total-consultations uint u0)
(define-data-var total-prescriptions uint u0)
(define-data-var total-deliveries uint u0)
(define-data-var administrator principal contract-owner)

;; Data Maps

;; Consultation records
(define-map consultations
  { consultation-id: uint }
  {
    patient: principal,
    provider: principal,
    scheduled-time: uint,
    status: (string-ascii 20),
    diagnosis: (optional (string-ascii 200)),
    completed-at: (optional uint),
    created-at: uint
  }
)

;; Prescription records
(define-map prescriptions
  { prescription-id: uint }
  {
    consultation-id: uint,
    patient: principal,
    provider: principal,
    medication-name: (string-ascii 100),
    dosage: (string-ascii 50),
    instructions: (string-ascii 200),
    quantity: uint,
    status: (string-ascii 20),
    pharmacy: (optional principal),
    issued-at: uint,
    expires-at: uint
  }
)

;; Pharmacy fulfillment orders
(define-map pharmacy-orders
  { order-id: uint }
  {
    prescription-id: uint,
    pharmacy: principal,
    status: (string-ascii 20),
    fulfilled-at: (optional uint),
    notes: (optional (string-ascii 200))
  }
)

;; Delivery tracking
(define-map deliveries
  { delivery-id: uint }
  {
    order-id: uint,
    patient: principal,
    delivery-address: (string-ascii 200),
    scheduled-time: uint,
    status: (string-ascii 20),
    delivered-at: (optional uint),
    delivered-by: (optional principal)
  }
)

;; Patient adherence tracking
(define-map adherence-records
  { patient: principal, prescription-id: uint }
  {
    pickup-confirmed: bool,
    pickup-date: (optional uint),
    adherence-score: uint,
    last-updated: uint
  }
)

;; Authorized providers
(define-map authorized-providers
  { provider: principal }
  { authorized: bool, specialty: (string-ascii 50) }
)

;; Authorized pharmacies
(define-map authorized-pharmacies
  { pharmacy: principal }
  { authorized: bool, name: (string-ascii 100) }
)

;; Authorized delivery personnel
(define-map authorized-delivery
  { delivery-person: principal }
  { authorized: bool }
)

(define-data-var prescription-nonce uint u0)
(define-data-var order-nonce uint u0)
(define-data-var delivery-nonce uint u0)

;; Public Functions

;; Schedule a telehealth consultation
(define-public (schedule-consultation (consultation-id uint) (patient principal) (provider principal) (scheduled-time uint))
  (begin
    (asserts! (is-authorized-provider provider) err-unauthorized)
    (asserts! (is-none (map-get? consultations { consultation-id: consultation-id })) err-already-exists)
    (asserts! (> scheduled-time block-height) err-invalid-value)
    
    (map-set consultations
      { consultation-id: consultation-id }
      {
        patient: patient,
        provider: provider,
        scheduled-time: scheduled-time,
        status: "scheduled",
        diagnosis: none,
        completed-at: none,
        created-at: block-height
      }
    )
    
    (var-set total-consultations (+ (var-get total-consultations) u1))
    (ok consultation-id)
  )
)

;; Complete consultation with diagnosis
(define-public (complete-consultation (consultation-id uint) (diagnosis (string-ascii 200)))
  (let
    (
      (consultation (unwrap! (map-get? consultations { consultation-id: consultation-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender (get provider consultation)) err-not-provider)
    (asserts! (is-eq (get status consultation) "scheduled") err-invalid-status)
    
    (map-set consultations
      { consultation-id: consultation-id }
      (merge consultation {
        status: "completed",
        diagnosis: (some diagnosis),
        completed-at: (some block-height)
      })
    )
    
    (ok true)
  )
)

;; Create prescription after consultation
(define-public (create-prescription (consultation-id uint) (medication-name (string-ascii 100)) (dosage (string-ascii 50)) (instructions (string-ascii 200)) (quantity uint) (validity-period uint))
  (let
    (
      (consultation (unwrap! (map-get? consultations { consultation-id: consultation-id }) err-not-found))
      (prescription-id (var-get prescription-nonce))
    )
    (asserts! (is-eq tx-sender (get provider consultation)) err-not-provider)
    (asserts! (is-eq (get status consultation) "completed") err-invalid-status)
    (asserts! (> quantity u0) err-invalid-value)
    
    (map-set prescriptions
      { prescription-id: prescription-id }
      {
        consultation-id: consultation-id,
        patient: (get patient consultation),
        provider: tx-sender,
        medication-name: medication-name,
        dosage: dosage,
        instructions: instructions,
        quantity: quantity,
        status: "issued",
        pharmacy: none,
        issued-at: block-height,
        expires-at: (+ block-height validity-period)
      }
    )
    
    (var-set prescription-nonce (+ prescription-id u1))
    (var-set total-prescriptions (+ (var-get total-prescriptions) u1))
    (ok prescription-id)
  )
)

;; Transmit prescription to pharmacy
(define-public (transmit-to-pharmacy (prescription-id uint) (pharmacy principal))
  (let
    (
      (prescription (unwrap! (map-get? prescriptions { prescription-id: prescription-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get patient prescription)) (is-eq tx-sender (get provider prescription))) err-unauthorized)
    (asserts! (is-authorized-pharmacy pharmacy) err-unauthorized)
    (asserts! (is-eq (get status prescription) "issued") err-invalid-status)
    (asserts! (< block-height (get expires-at prescription)) err-prescription-expired)
    
    (map-set prescriptions
      { prescription-id: prescription-id }
      (merge prescription {
        status: "transmitted",
        pharmacy: (some pharmacy)
      })
    )
    
    (ok true)
  )
)

;; Pharmacy fulfills prescription
(define-public (fulfill-prescription (prescription-id uint) (notes (string-ascii 200)))
  (let
    (
      (prescription (unwrap! (map-get? prescriptions { prescription-id: prescription-id }) err-not-found))
      (order-id (var-get order-nonce))
    )
    (asserts! (is-authorized-pharmacy tx-sender) err-unauthorized)
    (asserts! (is-eq (some tx-sender) (get pharmacy prescription)) err-unauthorized)
    (asserts! (is-eq (get status prescription) "transmitted") err-invalid-status)
    
    ;; Update prescription status
    (map-set prescriptions
      { prescription-id: prescription-id }
      (merge prescription { status: "fulfilled" })
    )
    
    ;; Create pharmacy order record
    (map-set pharmacy-orders
      { order-id: order-id }
      {
        prescription-id: prescription-id,
        pharmacy: tx-sender,
        status: "fulfilled",
        fulfilled-at: (some block-height),
        notes: (some notes)
      }
    )
    
    (var-set order-nonce (+ order-id u1))
    (ok order-id)
  )
)

;; Schedule delivery for fulfilled prescription
(define-public (schedule-delivery (order-id uint) (delivery-address (string-ascii 200)) (scheduled-time uint))
  (let
    (
      (order (unwrap! (map-get? pharmacy-orders { order-id: order-id }) err-not-found))
      (prescription (unwrap! (map-get? prescriptions { prescription-id: (get prescription-id order) }) err-not-found))
      (delivery-id (var-get delivery-nonce))
    )
    (asserts! (is-eq tx-sender (get pharmacy order)) err-unauthorized)
    (asserts! (is-eq (get status order) "fulfilled") err-invalid-status)
    
    (map-set deliveries
      { delivery-id: delivery-id }
      {
        order-id: order-id,
        patient: (get patient prescription),
        delivery-address: delivery-address,
        scheduled-time: scheduled-time,
        status: "scheduled",
        delivered-at: none,
        delivered-by: none
      }
    )
    
    (var-set delivery-nonce (+ delivery-id u1))
    (var-set total-deliveries (+ (var-get total-deliveries) u1))
    (ok delivery-id)
  )
)

;; Confirm delivery
(define-public (confirm-delivery (delivery-id uint))
  (let
    (
      (delivery (unwrap! (map-get? deliveries { delivery-id: delivery-id }) err-not-found))
    )
    (asserts! (is-authorized-delivery-person tx-sender) err-unauthorized)
    (asserts! (is-eq (get status delivery) "scheduled") err-invalid-status)
    
    (map-set deliveries
      { delivery-id: delivery-id }
      (merge delivery {
        status: "delivered",
        delivered-at: (some block-height),
        delivered-by: (some tx-sender)
      })
    )
    
    (ok true)
  )
)

;; Track patient adherence
(define-public (record-adherence (prescription-id uint) (pickup-confirmed bool) (adherence-score uint))
  (let
    (
      (prescription (unwrap! (map-get? prescriptions { prescription-id: prescription-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get patient prescription)) (is-authorized-provider tx-sender)) err-unauthorized)
    (asserts! (<= adherence-score u100) err-invalid-value)
    
    (map-set adherence-records
      { patient: (get patient prescription), prescription-id: prescription-id }
      {
        pickup-confirmed: pickup-confirmed,
        pickup-date: (if pickup-confirmed (some block-height) none),
        adherence-score: adherence-score,
        last-updated: block-height
      }
    )
    
    (ok true)
  )
)

;; Authorize provider
(define-public (authorize-provider (provider principal) (specialty (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender (var-get administrator)) err-owner-only)
    (ok (map-set authorized-providers
      { provider: provider }
      { authorized: true, specialty: specialty }
    ))
  )
)

;; Authorize pharmacy
(define-public (authorize-pharmacy (pharmacy principal) (name (string-ascii 100)))
  (begin
    (asserts! (is-eq tx-sender (var-get administrator)) err-owner-only)
    (ok (map-set authorized-pharmacies
      { pharmacy: pharmacy }
      { authorized: true, name: name }
    ))
  )
)

;; Authorize delivery personnel
(define-public (authorize-delivery-person (delivery-person principal))
  (begin
    (asserts! (is-eq tx-sender (var-get administrator)) err-owner-only)
    (ok (map-set authorized-delivery
      { delivery-person: delivery-person }
      { authorized: true }
    ))
  )
)

;; Read-only Functions

;; Get consultation details
(define-read-only (get-consultation (consultation-id uint))
  (map-get? consultations { consultation-id: consultation-id })
)

;; Get prescription details
(define-read-only (get-prescription (prescription-id uint))
  (map-get? prescriptions { prescription-id: prescription-id })
)

;; Get pharmacy order details
(define-read-only (get-pharmacy-order (order-id uint))
  (map-get? pharmacy-orders { order-id: order-id })
)

;; Get delivery details
(define-read-only (get-delivery (delivery-id uint))
  (map-get? deliveries { delivery-id: delivery-id })
)

;; Get adherence record
(define-read-only (get-adherence-record (patient principal) (prescription-id uint))
  (map-get? adherence-records { patient: patient, prescription-id: prescription-id })
)

;; Get total consultations
(define-read-only (get-total-consultations)
  (ok (var-get total-consultations))
)

;; Get total prescriptions
(define-read-only (get-total-prescriptions)
  (ok (var-get total-prescriptions))
)

;; Get total deliveries
(define-read-only (get-total-deliveries)
  (ok (var-get total-deliveries))
)

;; Check if provider is authorized
(define-read-only (is-provider-authorized (provider principal))
  (default-to false (get authorized (map-get? authorized-providers { provider: provider })))
)

;; Check if pharmacy is authorized
(define-read-only (is-pharmacy-authorized (pharmacy principal))
  (default-to false (get authorized (map-get? authorized-pharmacies { pharmacy: pharmacy })))
)

;; Private Functions

;; Check if caller is authorized provider
(define-private (is-authorized-provider (provider principal))
  (default-to false (get authorized (map-get? authorized-providers { provider: provider })))
)

;; Check if caller is authorized pharmacy
(define-private (is-authorized-pharmacy (pharmacy principal))
  (default-to false (get authorized (map-get? authorized-pharmacies { pharmacy: pharmacy })))
)

;; Check if caller is authorized delivery person
(define-private (is-authorized-delivery-person (delivery-person principal))
  (default-to false (get authorized (map-get? authorized-delivery { delivery-person: delivery-person })))
)

